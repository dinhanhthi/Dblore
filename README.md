# SQLNotebook

A native macOS application for writing and executing SQL queries in a cell-based interface similar to Jupyter Notebook. Supports PostgreSQL and SQLite with persistent query results.

## ✨ Features

- 📝 Cell-based interface with SQL and Markdown cells
- 🚀 Execute queries with syntax highlighting
- 💾 Save notebooks as `.sqlnb` files (JSON format)
- 📊 Display results in table format with integrated JSON viewer
- 🔌 Connect to PostgreSQL and SQLite
- ⚡ Native macOS app with SwiftUI

## 🛠️ Tech Stack

- **Language:** Swift 6+
- **UI Framework:** SwiftUI
- **Target:** macOS 15.0+
- **Architecture:** MVVM with Observable macro
- **Database:** PostgreSQL (PostgresNIO), SQLite (native)
- **Persistence:** Codable + JSON (`.sqlnb` files)

## 🚀 Development

### Requirements

- macOS 16.0+
- Xcode 16.0+
- Swift 6.0+

### Installation

```bash
# Clone repository
git clone https://github.com/yourusername/SQLNotebook.git
cd SQLNotebook

# Open project in Xcode
open SQLNotebook.xcodeproj

# Build and run (Cmd+R)
```

### Package Dependencies

Swift Package Manager will automatically fetch dependencies:
- [PostgresNIO](https://github.com/vapor/postgres-nio) - PostgreSQL client

### Testing Environment Setup

1. Open Project in Xcode → Wait for indexing to complete
2. Go to File → New → Target... then select macOS → search “Unit Testing Bundle” → Next → SQLNotebookTests → … → Finish
3. The same as 2 but choose “UI Testing Bundle” → name SQLNotebookUITests → … → Finish.
4. Verify that there are new folders in the project: SQLNotebook (main app), SQLNotebookTests, SQLNotebookUITests. Normally, they are already integrated in this repository.
5. Product → Scheme → Edit Scheme → in the left, choose Test/Test, we should see Test Plans “SQLNotebook” (2 test targets)
6. Don't add any dependency for test target. Otherwise, we get a building error with PostgresNIO.

## 📁 File Format

Notebooks are saved as `.sqlnb` files (JSON):
- Contains cells (SQL/Markdown)
- Stores execution results
- Connection configuration
- Metadata (timestamps, execution counts)

## 📚 Documentation

See [docs/project.md](docs/project.md) for detailed information, [docs/TODO.md] for TODO.

## 📝 License

MIT