//
//  SchemaGraphView+ContextMenu.swift
//  Dblore
//
//  The diagram's edit menus: a table header (Rename Table…, Add Column…, New Table…), a
//  column row (Rename Column…, Drop Column) and a relationship line (Drop Foreign Key). Items
//  are disabled with the reason as a last disabled item when the connection cannot change
//  tables (or, for foreign keys, on SQLite).
//

import AppKit

/// An edit picked on the diagram (a menu item, or a foreign-key drag dropped on a column)
enum SchemaDiagramEditAction {
  case renameTable(SchemaNode)
  case addColumn(SchemaNode)
  /// New Table in the schema of the clicked table
  case newTable(schema: String)
  case renameColumn(SchemaNode, column: String)
  case dropColumn(SchemaNode, column: String)
  case dropForeignKey(ForeignKey)
  case addForeignKey(from: SchemaNode, column: String, to: SchemaNode, targetColumn: String)
}

extension SchemaGraphNSView {
  /// The menu of the header, column row or relationship line under `event`; nil elsewhere or
  /// when the diagram does not edit
  func editMenu(for event: NSEvent) -> NSMenu? {
    guard onEditAction != nil else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    if let node = hitTestNode(at: point) {
      if let index = hitTestColumnIndex(in: node, at: point) {
        let column = node.table.columns[index].name
        return menu(
          items: [
            ("Rename Column…", .renameColumn(node, column: column)),
            ("Drop Column", .dropColumn(node, column: column)),
          ], reason: editDisabledReason)
      }
      guard isOnHeader(of: node, at: point) else { return nil }
      return menu(
        items: [
          ("Rename Table…", .renameTable(node)),
          ("Add Column…", .addColumn(node)),
          ("New Table…", .newTable(schema: node.table.schema)),
        ], reason: editDisabledReason)
    }
    guard showTableConnections, let edge = hitTestEdge(at: point) else { return nil }
    return menu(
      items: [("Drop Foreign Key", .dropForeignKey(edge.foreignKey))],
      reason: editDisabledReason ?? foreignKeyDisabledReason)
  }

  /// `items`, all disabled when `reason` is set (shown as a last disabled item)
  private func menu(items: [(String, SchemaDiagramEditAction)], reason: String?) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (title, action) in items {
      let item = NSMenuItem(
        title: title, action: #selector(performEditMenuItem(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = EditActionBox(action)
      item.isEnabled = reason == nil
      menu.addItem(item)
    }
    if let reason {
      menu.addItem(.separator())
      let note = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
      note.isEnabled = false
      menu.addItem(note)
    }
    return menu
  }

  @objc private func performEditMenuItem(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? EditActionBox else { return }
    onEditAction?(box.action)
  }
}

/// An action carried by a menu item (`representedObject` takes an object)
private final class EditActionBox {
  let action: SchemaDiagramEditAction

  init(_ action: SchemaDiagramEditAction) {
    self.action = action
  }
}
