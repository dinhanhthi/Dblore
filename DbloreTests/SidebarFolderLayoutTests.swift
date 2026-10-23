// SidebarFolderLayoutTests.swift
// The Public tab splits a schema's tables and views into its folders and the ungrouped rest.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Sidebar folder layout")
struct SidebarFolderLayoutTests {
  private struct Row: SidebarFolderItem, Equatable {
    let schema: String
    let name: String
    var folderSchema: String { schema }
    var folderMember: String { SidebarFolder.member(schema: schema, name: name) }
  }

  private static let users = Row(schema: "public", name: "users")
  private static let orders = Row(schema: "public", name: "orders")
  private static let logs = Row(schema: "public", name: "logs")
  private static let sales = Row(schema: "public", name: "v_sales")

  private static let folders = [
    SidebarFolder(
      name: "Auth", schema: "public",
      members: ["public.orders", "public.gone", "public.users"]),
    // Lists users too: the first folder keeps it
    SidebarFolder(name: "Billing", schema: "public", members: ["public.users", "public.v_sales"]),
    // A folder of another schema never takes a public row
    SidebarFolder(name: "Audit", schema: "audit", members: ["public.logs"]),
    SidebarFolder(name: "Empty", schema: "public"),
  ]

  @Test("A row sits in the first folder listing it; stale members are skipped")
  func grouping() {
    let layout = SidebarFolderLayout.build(
      folders: Self.folders, tables: [Self.users, Self.orders, Self.logs], views: [Self.sales],
      isFiltering: false)

    #expect(layout.groups.map(\.folder.name) == ["Auth", "Billing", "Audit", "Empty"])
    // Rows keep the schema list's order, not the folder's
    #expect(layout.groups[0].tables == [Self.users, Self.orders])
    #expect(layout.groups[1].tables.isEmpty)
    #expect(layout.groups[1].views == [Self.sales])
    #expect(layout.groups[2].count == 0)
    #expect(layout.tables == [Self.logs])
    #expect(layout.views.isEmpty)
  }

  @Test("While filtering, a folder without a listed row is left out")
  func filtering() {
    let layout = SidebarFolderLayout.build(
      folders: Self.folders, tables: [Self.orders], views: [Row](), isFiltering: true)

    #expect(layout.groups.map(\.folder.name) == ["Auth"])
    #expect(layout.groups[0].tables == [Self.orders])
    #expect(layout.tables.isEmpty)
  }
}
