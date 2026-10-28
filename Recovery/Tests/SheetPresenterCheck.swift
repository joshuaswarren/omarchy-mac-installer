import AppKit

@main struct Check {
  static func panel() -> NSPanel {
    NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled],
      backing: .buffered, defer: false)
  }

  static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }

  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(
      contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.orderFrontRegardless()
    let sheets = SheetPresenter()
    let details = panel()
    let issue = panel()
    var failurePending = false
    var dismissals = 0
    // Mirrors InstallerView.refresh(): a failure waiting behind an open sheet is shown on dismissal.
    sheets.onDismiss = {
      dismissals += 1
      if failurePending, sheets.active == nil {
        failurePending = false
        sheets.present(issue, on: window)
      }
    }

    precondition(sheets.present(details, on: window))
    precondition(!sheets.present(panel(), on: window), "second sheet accepted while one is open")
    settle()
    precondition(window.attachedSheet === details)
    failurePending = true
    sheets.close()
    settle()
    precondition(sheets.active === issue, "issue sheet raised during dismissal was forgotten")
    precondition(window.attachedSheet === issue)
    sheets.close()
    settle()
    precondition(sheets.active == nil && window.attachedSheet == nil, "issue sheet not dismissed")
    precondition(dismissals == 2)
    precondition(!sheets.present(panel(), on: nil), "presented without a window")

    // A password refused while Show details is open waits for it to close,
    // after onDismiss has cleared the old sheet's state.
    var order = [String]()
    sheets.onDismiss = { order.append("dismiss") }
    let authorization = panel()
    var immediate = false
    sheets.whenFree { immediate = true }
    precondition(immediate, "a free presenter must show at once")
    precondition(sheets.present(details, on: window))
    settle()
    sheets.whenFree {
      order.append("authorization")
      precondition(sheets.present(authorization, on: window))
    }
    precondition(order.isEmpty, "waiting request ran while a sheet was open")
    sheets.close()
    settle()
    precondition(order == ["dismiss", "authorization"], "\(order)")
    precondition(sheets.active === authorization && window.attachedSheet === authorization)
    sheets.close()
    settle()
    precondition(order == ["dismiss", "authorization", "dismiss"], "request ran twice: \(order)")

    // If onDismiss opens another sheet first, the request waits for that one.
    let notice = panel()
    order = []
    sheets.onDismiss = {
      order.append("dismiss")
      if order.count == 1 { sheets.present(notice, on: window) }
    }
    precondition(sheets.present(details, on: window))
    settle()
    sheets.whenFree {
      order.append("authorization")
      precondition(sheets.present(authorization, on: window))
    }
    sheets.close()
    settle()
    precondition(sheets.active === notice && order == ["dismiss"], "\(order)")
    sheets.close()
    settle()
    precondition(order == ["dismiss", "dismiss", "authorization"], "\(order)")
    precondition(sheets.active === authorization)
    sheets.close()
    settle()
    print(
      "PASS sheet lifecycle: a sheet raised while another closes stays dismissible; a waiting sheet opens once the others close"
    )
    window.orderOut(nil)
  }
}
