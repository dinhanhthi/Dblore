# Package Dependencies

The SQLNotebook project relies on several key Swift packages, primarily from the SwiftNIO ecosystem. The core functionality that drives these dependencies is the support for **PostgreSQL** via `PostgresNIO`.

Below is a breakdown of why each package is required.

## Core Database Driver
- **`postgres-nio`**: The primary driver used for connecting to and interacting with PostgreSQL databases. It is built on top of SwiftNIO to provide a non-blocking, asynchronous API.

## Network & Infrastructure (SwiftNIO Ecosystem)
Most of the dependencies listed are transitively required by `PostgresNIO` or used for low-level networking and concurrency management:

- **`swift-nio`**: The fundamental framework for high-performance, non-blocking networking in Swift. It handles the event loops and byte buffers used by the PostgreSQL driver.
- **`swift-nio-ssl`**: Provides TLS/SSL support for encrypted database connections.
- **`swift-nio-transport-services`**: Adapts SwiftNIO to use Apple's Network.framework, which is optimized for Apple platforms (macOS/iOS).
- **`NIOCore` / `NIOFoundationCompat`**: Core components of the NIO stack providing protocols and Foundation integration (as seen in `DatabaseConnectionManager.swift`).

## Security & Encoding
- **`swift-crypto`**: A cross-platform implementation of Apple's CryptoKit. It is used for secure password hashing and encryption during the database authentication process.
- **`swift-asn1`**: Used for parsing and encoding Abstract Syntax Notation One (ASN.1) data, which is common in cryptographic certificates and security protocols.

## Performance & Concurrency
- **`swift-async-algorithms`**: Provides a set of algorithms for working with `AsyncSequence`, such as debouncing, buffering, and merging streams of data (useful for handling database result streams).
- **`swift-atomics`**: Provides low-level atomic operations, ensuring thread safety for shared state without the overhead of locks in performance-critical sections.
- **`swift-collections`**: Offers additional data structures (like `Deque` or `OrderedDictionary`) that are more efficient than standard library types for certain use cases.

## System & Diagnostics
- **`swift-log`**: A logging API that allows the application to record internal behavior and errors (used in `DatabaseConnectionManager` to log connection events).
- **`swift-metrics`**: A standard metrics API for collecting performance data and telemetry.
- **`swift-service-lifecycle`**: Manages the startup and shutdown sequences of the application's services, ensuring resources like database connections are cleaned up properly.
- **`swift-system`**: Provides a type-safe interface to system calls (like file descriptor management), used for low-level platform interactions.
