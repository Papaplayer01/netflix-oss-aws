variable "region" {
  type    = string
  default = "ap-south-1" # Mumbai, closest to Nashik
}

variable "project" {
  type    = string
  default = "netflix-oss-aws" # keep in sync with PROJECT in deploy.sh
}

variable "namespace" {
  type    = string
  default = "netflix.local" # private DNS name inside the VPC
}

variable "cpu_architecture" {
  type    = string
  default = "X86_64" # build images with --platform linux/amd64 (deploy.sh does this)
}

variable "image_tag" {
  type    = string
  default = "latest" # GitHub Actions passes the commit SHA here
}
