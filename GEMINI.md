# SQLNotebook

A native macOS application for writing and executing SQL queries in a cell-based interface, similar to Jupyter Notebook. It supports PostgreSQL and SQLite, offering persistent query results and a rich user interface built with SwiftUI.

## Project Overview

*   **Type:** Native macOS Application (SwiftUI)
*   **Purpose:** Provide a notebook-style environment for SQL development and data analysis.
*   **Core Features:**
    *   Cell-based interface (SQL and Markdown).
    *   PostgreSQL and SQLite support.
    *   Result visualization (Table, JSON).
    *   `.sqlnb` file format for saving notebooks.
*   **Target Platform:** macOS 16.0+

## Architecture & Technologies

*   **Language:** Swift 6.0+
*   **UI Framework:** SwiftUI
*   **Architecture Pattern:** MVVM (Model-View-ViewModel) with `@Observable`.
*   **Database Connectivity:**
    *   **PostgreSQL:** `PostgresNIO` (SwiftNIO based driver).
    *   **SQLite:** Native integration.
*   **Persistence:** `Codable` structs serialized to JSON (`.sqlnb` files).

## Key Files & Structure

*   **`SQLNotebookApp.swift`**: The main entry point of the application.
*   **`Database/DatabaseConnectionManager.swift`**: An actor responsible for managing database connections (specifically Postgres via PostgresNIO) and executing queries. Handles connection lifecycle, SSL, and type mapping.
*   **`Models/NotebookCell.swift`**: Defines the data model for a single notebook cell (`NotebookCell`), including its type (SQL/Markdown), content, and execution results (`CellResult`).
*   **`Models/SQLNotebookDocument.swift`**: (Inferred) Likely manages the document-based application logic for `.sqlnb` files.
*   **`ViewModels/NotebookViewModel.swift`**: (Inferred) The ViewModel driving the notebook UI, handling cell execution logic and state management.

## Development

### Requirements
*   macOS 16.0+
*   Xcode 16.0+
*   Swift 6.0+

### Building & Running
1.  Open `SQLNotebook.xcodeproj` in Xcode.
2.  Wait for Swift Package Manager to resolve dependencies (e.g., `PostgresNIO`).
3.  Build and Run (Cmd+R).

### Conventions
*   **Concurrency:** Heavy usage of Swift Concurrency (`async`/`await`, `actor` for database management).
*   **UI:** SwiftUI views, using `Observable` objects for state.
*   **Error Handling:** Custom `DatabaseError` enum for standardized error reporting in database operations.
*   **Type Safety:** Strong typing for SQL results using `CellValue` enum to handle various database types (String, Int, Double, JSON, etc.).
