//
//  CellView+Previews.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Previews

#Preview("Empty Cells") {
  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: .constant(NotebookCell(cellType: .sql, content: "")),
        isSelected: false,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 700, height: 150)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Long Results") {
  @Previewable @State var cellWithResult = {
    let mockResult = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "email", type: "VARCHAR"),
        ColumnInfo(name: "description", type: "TEXT"),
        ColumnInfo(name: "age", type: "INTEGER"),
        ColumnInfo(name: "active", type: "BOOLEAN"),
        ColumnInfo(name: "metadata", type: "JSONB"),
      ],
      rows: [
        [
          .int(1), .string("Alice Johnson"), .string("alice@example.com"),
          .string(
            "Senior Software Engineer with expertise in iOS development, SwiftUI, and system architecture. Passionate about creating elegant user interfaces and scalable solutions."
          ), .int(28), .bool(true), .json("{\"role\": \"admin\", \"dept\": \"IT\"}"),
        ],
        [
          .int(2), .string("Bob Williams"), .string("bob@example.com"),
          .string(
            "Sales Manager responsible for the entire West Coast region, managing a team of 15 sales representatives and achieving consistent quarterly growth."
          ), .int(35), .bool(true), .json("{\"role\": \"user\", \"dept\": \"Sales\"}"),
        ],
        [
          .int(3), .string("Charlie Brown"), .string("charlie@example.com"),
          .string(
            "Product Designer specializing in user experience research and interface design. Led design initiatives for multiple successful product launches."
          ), .int(42), .bool(false), .null,
        ],
        [
          .int(4), .string("Diana Prince"), .string("diana@example.com"),
          .string(
            "Engineering Manager overseeing backend infrastructure team. Expert in distributed systems, microservices architecture, and cloud technologies."
          ), .int(31), .bool(true), .json("{\"role\": \"manager\"}"),
        ],
        [
          .int(5), .string("Eve Anderson"), .string("eve@example.com"),
          .string(
            "Data Scientist with focus on machine learning and predictive analytics. Published researcher in AI and natural language processing."
          ), .int(29), .bool(false), .null,
        ],
        [
          .int(6), .string("Frank Martinez"), .string("frank@example.com"),
          .string(
            "DevOps Engineer maintaining CI/CD pipelines and cloud infrastructure. Certified in AWS, Azure, and Kubernetes administration."
          ), .int(33), .bool(true), .json("{\"role\": \"user\", \"dept\": \"IT\"}"),
        ],
        [
          .int(7), .string("Grace Lee"), .string("grace@example.com"),
          .string(
            "Marketing Director developing comprehensive marketing strategies across digital and traditional channels with proven ROI improvement."
          ), .int(38), .bool(true), .json("{\"role\": \"manager\", \"dept\": \"Marketing\"}"),
        ],
        [
          .int(8), .string("Henry Taylor"), .string("henry@example.com"),
          .string(
            "Quality Assurance Lead ensuring product quality through automated testing frameworks and comprehensive test coverage strategies."
          ), .int(30), .bool(true), .json("{\"role\": \"user\", \"dept\": \"QA\"}"),
        ],
        [
          .int(9), .string("Iris Chen"), .string("iris@example.com"),
          .string(
            "Full-stack Developer building scalable web applications using modern frameworks and best practices in software engineering."
          ), .int(27), .bool(true), .json("{\"role\": \"user\", \"dept\": \"IT\"}"),
        ],
        [
          .int(10), .string("Jack Wilson"), .string("jack@example.com"),
          .string(
            "Security Analyst responsible for identifying vulnerabilities, implementing security protocols, and ensuring compliance with industry standards."
          ), .int(36), .bool(false), .json("{\"role\": \"user\", \"dept\": \"Security\"}"),
        ],
        [
          .int(11), .string("Kate Brown"), .string("kate@example.com"),
          .string(
            "Technical Writer creating comprehensive documentation, API references, and user guides for complex software systems and platforms."
          ), .int(32), .bool(true), .json("{\"role\": \"user\", \"dept\": \"Documentation\"}"),
        ],
        [
          .int(12), .string("Liam Davis"), .string("liam@example.com"),
          .string(
            "Mobile Developer specializing in cross-platform development with React Native and Flutter for iOS and Android applications."
          ), .int(28), .bool(true), .json("{\"role\": \"user\", \"dept\": \"Mobile\"}"),
        ],
        [
          .int(13), .string("Maya Patel"), .string("maya@example.com"),
          .string(
            "Business Analyst bridging technical and business stakeholders, defining requirements, and ensuring project alignment with business objectives."
          ), .int(34), .bool(true), .json("{\"role\": \"analyst\", \"dept\": \"Business\"}"),
        ],
        [
          .int(14), .string("Noah Garcia"), .string("noah@example.com"),
          .string(
            "System Administrator managing server infrastructure, network security, and ensuring high availability of critical business systems."
          ), .int(40), .bool(false), .null,
        ],
        [
          .int(15), .string("Olivia Smith"), .string("olivia@example.com"),
          .string(
            "Project Manager coordinating cross-functional teams, managing timelines and budgets, and delivering complex projects on schedule."
          ), .int(37), .bool(true), .json("{\"role\": \"manager\", \"dept\": \"PMO\"}"),
        ],
        [
          .int(16), .string("Paul Johnson"), .string("paul@example.com"),
          .string(
            "Database Administrator optimizing database performance, managing backups, and ensuring data integrity across multiple systems."
          ), .int(39), .bool(true), .json("{\"role\": \"user\", \"dept\": \"IT\"}"),
        ],
        [
          .int(17), .string("Quinn Roberts"), .string("quinn@example.com"),
          .string(
            "UX Researcher conducting user studies, analyzing behavior patterns, and providing insights to improve product usability and satisfaction."
          ), .int(31), .bool(true), .json("{\"role\": \"researcher\", \"dept\": \"Design\"}"),
        ],
        [
          .int(18), .string("Rachel Green"), .string("rachel@example.com"),
          .string(
            "Content Strategist developing content plans, managing editorial calendars, and ensuring consistent brand voice across all platforms."
          ), .int(33), .bool(false), .json("{\"role\": \"user\", \"dept\": \"Marketing\"}"),
        ],
      ],
      executionTime: 0.087,
      rowCount: 18,
      timestamp: Date()
    )

    var cell = NotebookCell(
      cellType: .sql,
      content:
        "SELECT id, name, email, description, age, active, metadata\nFROM users\nWHERE active = true\nORDER BY id;"
    )
    cell.result = mockResult
    cell.executionCount = 3
    return cell
  }()

  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: $cellWithResult,
        isSelected: true,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 800, height: 700)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Short Results") {
  @Previewable @State var cellWithResult = {
    let mockResult = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "status", type: "VARCHAR"),
      ],
      rows: [
        [.int(1), .string("Alice"), .string("Active")],
        [.int(2), .string("Bob"), .string("Inactive")],
        [.int(3), .string("Charlie"), .string("Active")],
        [.int(4), .string("Diana"), .string("Active")],
      ],
      executionTime: 0.012,
      rowCount: 4,
      timestamp: Date()
    )

    var cell = NotebookCell(
      cellType: .sql,
      content: "SELECT id, name, status\nFROM users\nLIMIT 4;"
    )
    cell.result = mockResult
    cell.executionCount = 1
    return cell
  }()

  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: $cellWithResult,
        isSelected: true,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 600, height: 400)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Error State") {
  @Previewable @State var cellWithError = {
    let errorResult = CellResult(
      columns: [],
      rows: [],
      executionTime: 0.003,
      rowCount: 0,
      timestamp: Date(),
      error:
        "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^"
    )

    var cell = NotebookCell(
      cellType: .sql,
      content: "SELECT invalid_column FROM users;"
    )
    cell.result = errorResult
    cell.executionCount = 5
    return cell
  }()

  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: $cellWithError,
        isSelected: false,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 600)
  .frame(maxHeight: .infinity)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
