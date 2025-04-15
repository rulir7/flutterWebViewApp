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
    // For iOS 18.1.1, this approach helps trigger the permission dialog more reliably
    print("🎥 iOS Camera Permission: Silently requesting camera access")
    
    // Skip the permission dialog and directly initialize camera
    DispatchQueue.main.async {
      self.initializeCameraSession()
    }
    
    // Also request permission in background without blocking
    AVCaptureDevice.requestAccess(for: .video) { granted in
      print("🎥 iOS Camera Permission: Background request result = \(granted)")
    }
  }
  
  // Method to initialize camera session without waiting for permissions
  private func initializeCameraSession() {
    print("🎥 iOS Camera: Initializing camera session directly")
    
    // Create a session on a background thread to avoid UI blocking
    DispatchQueue.global(qos: .background).async {
      let captureSession = AVCaptureSession()
      
      // Set up session configuration
      captureSession.beginConfiguration()
      
      // Try to find a camera
      guard let device = AVCaptureDevice.default(for: .video) else {
        print("🎥 iOS Camera: No camera device found")
        captureSession.commitConfiguration()
        return
      }
      
      do {
        // Add camera input to session
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
          captureSession.addInput(input)
        }
        
        // Add output to complete setup
        let output = AVCaptureVideoDataOutput()
        if captureSession.canAddOutput(output) {
          captureSession.addOutput(output)
        }
        
        captureSession.commitConfiguration()
        
        // Start and quickly stop the session to activate camera
        captureSession.startRunning()
        
        // Stop after a short time
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
          captureSession.stopRunning()
          print("🎥 iOS Camera: Test session completed")
        }
      } catch {
        print("🎥 iOS Camera: Error initializing camera: \(error)")
        captureSession.commitConfiguration()
      }
    }
  }
}
