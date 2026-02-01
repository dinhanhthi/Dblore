//
//  SizeReader.swift
//  SQLNotebook
//
//  Performance-optimized size reading utility for SwiftUI views.
//  Uses onGeometryChange modifier to avoid unnecessary re-renders.
//

import SwiftUI

/// A view modifier that reads the size of a view and stores it in a binding.
///
/// This is more performant than using GeometryReader directly because:
/// - It only updates the size when it actually changes (not on every layout pass)
/// - It uses the efficient onGeometryChange modifier
/// - It doesn't require wrapping content in GeometryReader
///
/// Usage:
/// ```swift
/// @State private var contentSize: CGSize = .zero
///
/// MyView()
///   .readSize($contentSize)
/// ```
struct SizeReaderModifier: ViewModifier {
  @Binding var size: CGSize

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { newSize in
        // Only update if size actually changed to avoid unnecessary re-renders
        if size != newSize {
          size = newSize
        }
      }
  }
}

extension View {
  /// Reads the size of the view and stores it in the provided binding.
  ///
  /// This modifier efficiently tracks size changes without causing unnecessary re-renders.
  /// The size is only updated when it actually changes.
  ///
  /// - Parameter size: A binding to store the view's size
  /// - Returns: A modified view that tracks its size
  func readSize(_ size: Binding<CGSize>) -> some View {
    modifier(SizeReaderModifier(size: size))
  }
}

/// A container view that provides its size to the content closure.
///
/// This is a more performant alternative to GeometryReader for cases where
/// you only need the container size and not the full geometry information.
///
/// Features:
/// - Only updates when size actually changes
/// - Avoids unnecessary re-renders caused by GeometryReader
/// - Simple API focused on size reading
///
/// Usage:
/// ```swift
/// SizeReader { size in
///   VStack {
///     Text("Width: \(size.width)")
///     Text("Height: \(size.height)")
///   }
/// }
/// ```
struct SizeReader<Content: View>: View {
  @State private var size: CGSize = .zero
  let content: (CGSize) -> Content

  init(@ViewBuilder content: @escaping (CGSize) -> Content) {
    self.content = content
  }

  var body: some View {
    Color.clear
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { newSize in
        if size != newSize {
          size = newSize
        }
      }
      .overlay {
        // Only render content when we have valid dimensions
        // This prevents "Invalid view geometry: width is negative" warnings
        // that occur when content tries to use zero/negative dimensions
        if size.width > 0 && size.height > 0 {
          content(size)
        }
      }
  }
}

#Preview("SizeReader") {
  SizeReader { size in
    VStack {
      Text("Container Size")
        .font(.headline)
      Text("Width: \(Int(size.width))")
      Text("Height: \(Int(size.height))")
    }
    .padding()
    .background(Color.blue.opacity(0.2))
    .cornerRadius(8)
  }
  .frame(width: 300, height: 200)
  .background(Color.gray.opacity(0.1))
}
