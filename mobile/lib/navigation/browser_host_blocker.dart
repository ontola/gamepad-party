/// Why a page can't be the TV screen (the browser host, /play/).
enum BrowserHostBlocker {
  /// Not a browser: the app on a phone or computer.
  app,

  /// A phone or tablet browser: the browser host is made for a PC (phones
  /// host from the Android app instead).
  phone,

  /// A computer browser without (working) WebGPU.
  browser,
}
