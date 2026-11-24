/// Why a page can't be the TV screen (the browser host, /play/).
enum BrowserHostBlocker {
  /// Not a browser: the app on a phone or computer.
  app,

  /// A phone or tablet: too slow to be the TV screen.
  phone,

  /// A computer browser without (working) WebGPU.
  browser,
}
