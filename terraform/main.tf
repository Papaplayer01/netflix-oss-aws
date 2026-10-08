terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Learning setup: use the default VPC and its public subnets (no NAT gateway = cheaper).
# For production use private subnets + NAT / VPC endpoints.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  services = {
    "discovery-server" = { port = 8761 }
    "api-gateway"      = { port = 8080 }
    "product-service"  = { port = 8081 }
    "order-service"    = { port = 8082 }
  }
  eureka_url = "http://discovery.${var.namespace}:8761/eureka"
}

# ---------- Container registries ----------
resource "aws_ecr_repository" "svc" {
  for_each             = local.services
  name                 = "${var.project}/${each.key}"
  force_delete         = true # lets `terraform destroy` remove repos that still hold images
  image_tag_mutability = "MUTABLE"
}

# ---------- Logs ----------
resource "aws_cloudwatch_log_group" "svc" {
  for_each          = local.services
  name              = "/ecs/${var.project}/${each.key}"
  retention_in_days = 7
}

# ---------- IAM ----------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.project}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------- Security groups ----------
resource "aws_security_group" "alb" {
  name   = "${var.project}-alb"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "tasks" {
  name   = "${var.project}-tasks"
  vpc_id = data.aws_vpc.default.id

  # services may talk to each other on any port
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
  # the load balancer may reach the gateway
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- Cloud Map: private DNS so services can find the Eureka server ----------
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = var.namespace
  vpc  = data.aws_vpc.default.id
}

resource "aws_service_discovery_service" "discovery" {
  name = "discovery"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

# ---------- Load balancer (public entry point -> API gateway) ----------
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "gateway" {
  name        = "${var.project}-gw"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip" # required for Fargate (awsvpc)
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

# ---------- ECS ----------
resource "aws_ecs_cluster" "main" {
  name = var.project
}

resource "aws_ecs_task_definition" "svc" {
  for_each                 = local.services
  family                   = "${var.project}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([{
    name         = each.key
    image        = "${aws_ecr_repository.svc[each.key].repository_url}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = each.value.port, protocol = "tcp" }]
    environment  = [{ name = "EUREKA_URL", value = local.eureka_url }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.svc[each.key].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "svc" {
  for_each        = local.services
  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true # needed to pull images without a NAT gateway
  }

  # only the Eureka server registers in Cloud Map DNS
  dynamic "service_registries" {
    for_each = each.key == "discovery-server" ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.discovery.arn
    }
  }

  # only the gateway sits behind the load balancer
  dynamic "load_balancer" {
    for_each = each.key == "api-gateway" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.gateway.arn
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  health_check_grace_period_seconds = each.key == "api-gateway" ? 120 : null

  depends_on = [aws_lb_listener.http]
}
