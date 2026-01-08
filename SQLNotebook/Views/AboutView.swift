//
//  AboutView.swift
//  SQLNotebook
//

import SwiftUI

struct AboutView: View {
  var body: some View {
    VStack(spacing: Spacing.xl) {
      // App Icon and Name
      VStack(spacing: Spacing.md) {
        Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
          .resizable()
          .frame(width: 80, height: 80)

        Text("SQLNotebook")
          .font(.title)
          .fontWeight(.semibold)

        Text("Version \(appVersion)")
          .font(.subheading)
          .foregroundColor(.foregroundSubtle)

        Link(
          "github.com/dinhanhthi/SQLNotebook",
          destination: URL(string: "https://github.com/dinhanhthi/SQLNotebook")!
        )
        .font(.bodyText)
      }

      // Copyright
      HStack {
        Link(
          "Anh-Thi Dinh",
          destination: URL(string: "https://dinhanhthi.com")!
        )
        .font(.labelText)

        Text(
          "© \(currentYear)"
        )
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
      }
    }
    .padding(Spacing.xl)
    .frame(width: 360)
    .background(Color.cardBackground)
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
  }

  private var currentYear: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy"
    return formatter.string(from: Date())
  }
}

#Preview {
  AboutView()
    .preferredColorScheme(.dark)
}
