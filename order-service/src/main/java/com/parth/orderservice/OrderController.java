package com.parth.orderservice;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import org.springframework.cloud.client.circuitbreaker.CircuitBreakerFactory;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    public record OrderRequest(long productId, int quantity) {}
    public record Product(long id, String name, double price) {}
    public record Order(long id, long productId, int quantity, double total, String status) {}

    private final RestTemplate restTemplate;
    private final CircuitBreakerFactory<?, ?> circuitBreakerFactory;
    private final Map<Long, Order> orders = new ConcurrentHashMap<>();
    private final AtomicLong sequence = new AtomicLong(1);

    public OrderController(RestTemplate restTemplate, CircuitBreakerFactory<?, ?> circuitBreakerFactory) {
        this.restTemplate = restTemplate;
        this.circuitBreakerFactory = circuitBreakerFactory;
    }

    @PostMapping
    public Order create(@RequestBody OrderRequest req) {
        Order order = circuitBreakerFactory.create("productCb").run(
                // normal path: ask product-service (found through Eureka) for the price
                () -> {
                    Product p = restTemplate.getForObject(
                            "http://product-service/api/products/{id}", Product.class, req.productId());
                    if (p == null) {
                        throw new IllegalStateException("empty response");
                    }
                    return new Order(sequence.getAndIncrement(), req.productId(), req.quantity(),
                            p.price() * req.quantity(), "CONFIRMED");
                },
                // fallback: product-service is down or the circuit is open
                throwable -> new Order(sequence.getAndIncrement(), req.productId(), req.quantity(),
                        0, "PENDING_PRODUCT_SERVICE_UNAVAILABLE"));
        orders.put(order.id(), order);
        return order;
    }

    @GetMapping
    public List<Order> all() {
        return new ArrayList<>(orders.values());
    }
}
