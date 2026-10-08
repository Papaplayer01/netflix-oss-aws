package com.parth.productservice;

import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api/products")
public class ProductController {

    public record Product(long id, String name, double price) {}

    private final List<Product> products = List.of(
            new Product(1, "Laptop", 55000),
            new Product(2, "Keyboard", 1500),
            new Product(3, "Mouse", 700));

    // Chaos switch: lets you break this service on purpose to see the circuit breaker work.
    private final AtomicBoolean failing = new AtomicBoolean(false);

    @GetMapping
    public List<Product> all() {
        return products;
    }

    @GetMapping("/{id}")
    public Product byId(@PathVariable long id) {
        if (failing.get()) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "chaos mode is ON");
        }
        return products.stream().filter(p -> p.id() == id).findFirst()
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "no such product"));
    }

    @PostMapping("/chaos")
    public String chaos(@RequestParam boolean fail) {
        failing.set(fail);
        return "chaos mode = " + fail;
    }
}
