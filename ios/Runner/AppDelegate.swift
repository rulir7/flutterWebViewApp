import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Request camera permissions directly at app startup
    requestCameraPermission()
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  // Function to directly request camera permission
  private func requestCameraPermission() {
    // For iOS 18.1.1, this helps trigger the permission dialog
    AVCaptureDevice.requestAccess(for: .video) { granted in
      print("Camera permission request result: \(granted)")
    }
  }
}
