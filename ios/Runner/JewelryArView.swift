import AVFoundation
import Flutter
import MediaPipeTasksVision
import SceneKit
import UIKit
import ModelIO
import SceneKit.ModelIO

/// Native UIView that composites:
///   1. AVCaptureVideoPreviewLayer (camera feed)
///   2. SCNView (3D ring rendered via SceneKit)
///   3. MediaPipe Hands (real-time 3D landmark detection)
///
/// Landmark events are streamed back to Flutter via EventChannel.
class JewelryArView: UIView {

  // MARK: - Camera

  private let captureSession = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer!
  private let videoOutput = AVCaptureVideoDataOutput()
  private let videoQueue = DispatchQueue(label: "com.jewelry.videoQueue", qos: .userInteractive)

  // MARK: - SceneKit

  private let scnView = SCNView()
  private var ringNode: SCNNode?
  private var fingerOccluderNode: SCNNode?

  // MARK: - Debug overlay

  private let debugOverlay = DebugOverlayView()

  // MARK: - MediaPipe

  private var handLandmarker: HandLandmarker?
  private var lastTimestampMs: Int = 0

  // MARK: - Flutter channels

  private var eventSink: FlutterEventSink?
  private let eventChannel: FlutterEventChannel

  // MARK: - Configuration

  private let modelAsset: String
  private var ringSize: Int

  // MARK: - One-Euro Filters (adaptive smoothing: smooth when still, responsive when fast)

  private var filterPosX = OneEuroFilter(minCutoff: 1.5, beta: 0.6)
  private var filterPosY = OneEuroFilter(minCutoff: 1.5, beta: 0.6)
  private var filterScale = OneEuroFilter(minCutoff: 0.4, beta: 0.08)
  private var smoothedRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
  private var hasSmoothedValues = false
  private let rotationAlpha: Float = 0.35

  // Grace period: keep showing ring briefly when tracking is lost
  private var framesWithoutDetection = 0
  private let gracePeriodFrames = 8

  // MARK: - Init

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    modelAsset = args["modelAsset"] as? String ?? "assets/ring.glb"
    ringSize = args["ringSize"] as? Int ?? 3

    eventChannel = FlutterEventChannel(
      name: "jewelry_ar_view_events",
      binaryMessenger: messenger
    )

    super.init(frame: frame)

    eventChannel.setStreamHandler(self)
    setupCamera()
    setupSceneKit()
    setupMediaPipe()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) not supported")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    previewLayer?.frame = bounds
    scnView.frame = bounds
    debugOverlay.frame = bounds
  }

  // MARK: - Camera setup

  private func setupCamera() {
    captureSession.sessionPreset = .hd1280x720

    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: device)
    else { return }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    // Fix orientation for portrait
    if let connection = videoOutput.connection(with: .video) {
      if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(90) {
          connection.videoRotationAngle = 90
        }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
      }
    }

    previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.frame = bounds
    layer.addSublayer(previewLayer)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.captureSession.startRunning()
    }
  }

  // MARK: - SceneKit setup

  private func setupSceneKit() {
    scnView.frame = bounds
    scnView.backgroundColor = .clear
    scnView.scene = SCNScene()
    scnView.autoenablesDefaultLighting = true // Faster for debugging
    scnView.allowsCameraControl = false
    scnView.isPlaying = true
    scnView.layer.zPosition = 100 // Ensure it is above the preview layer
    addSubview(scnView)

    // Camera node matching roughly a phone back-camera FOV (~60°)
    let cameraNode = SCNNode()
    cameraNode.camera = SCNCamera()
    cameraNode.camera?.fieldOfView = 60
    cameraNode.camera?.zNear = 0.01 // Increased to avoid clipping
    cameraNode.camera?.zFar = 10
    cameraNode.position = SCNVector3(0, 0, 0)
    scnView.scene?.rootNode.addChildNode(cameraNode)
    scnView.pointOfView = cameraNode

    loadRingModel()
    setupFingerOccluder()
  }

  private func setupFingerOccluder() {
    // Invisible occluder: writes only to depth buffer, no color output.
    let geometry = SCNCylinder(radius: 0.01, height: 0.03) // Larger initial size
    let material = SCNMaterial()
    material.diffuse.contents = UIColor.black
    material.colorBufferWriteMask = []
    material.writesToDepthBuffer = true
    material.readsFromDepthBuffer = true
    material.isDoubleSided = true
    geometry.materials = [material]

    let node = SCNNode(geometry: geometry)
    node.renderingOrder = -10
    node.isHidden = true
    fingerOccluderNode = node
    scnView.scene?.rootNode.addChildNode(node)
  }

  private func loadRingModel() {
    print("[JewelryAR] ℹ️ loadRingModel called with asset: \(modelAsset)")
    let assetKey = FlutterDartProject.lookupKey(forAsset: modelAsset)
    guard let bundlePath = Bundle.main.path(forResource: assetKey, ofType: nil) else {
      print("[JewelryAR] ❌ ring model not found at asset key: \(assetKey)")
      buildFallbackRing()
      return
    }
    let url = URL(fileURLWithPath: bundlePath)

    do {
      let mdlAsset = MDLAsset(url: url)
      mdlAsset.loadTextures()
      let modelScene = SCNScene(mdlAsset: mdlAsset)
      
      let containerNode = SCNNode()
      for child in modelScene.rootNode.childNodes {
        containerNode.addChildNode(child)
      }
      
      if containsGeometry(node: containerNode) {
        containerNode.isHidden = true
        ringNode = containerNode
        scnView.scene?.rootNode.addChildNode(containerNode)
        print("[JewelryAR] ✅ ring model loaded successfully from GLB")
      } else {
        print("[JewelryAR] ❌ GLB has no geometry, using fallback")
        buildFallbackRing()
      }
    } catch {
      print("[JewelryAR] ❌ Error loading GLB: \(error)")
      buildFallbackRing()
    }
  }

  private func containsGeometry(node: SCNNode) -> Bool {
    if node.geometry != nil { return true }
    for child in node.childNodes {
      if containsGeometry(node: child) { return true }
    }
    return false
  }

  private func buildFallbackRing() {
    // A torus with total diameter of 1.0 unit
    let torus = SCNTorus(ringRadius: 0.45, pipeRadius: 0.05)
    let material = SCNMaterial()
    material.lightingModel = .phong
    material.diffuse.contents = UIColor.systemYellow
    material.specular.contents = UIColor.white
    material.shininess = 0.9
    torus.materials = [material]

    let fallbackNode = SCNNode(geometry: torus)
    
    // Add a RED marker on "top" (Z-axis in our matrix alignment)
    // This will help verify if the ring stays on top of the finger.
    let markerGeo = SCNSphere(radius: 0.12)
    let markerMat = SCNMaterial()
    markerMat.diffuse.contents = UIColor.systemRed
    markerMat.lightingModel = .phong
    markerGeo.materials = [markerMat]
    
    let markerNode = SCNNode(geometry: markerGeo)
    // Position it on the outer edge of the torus along the Z axis (upVec)
    markerNode.position = SCNVector3(0, 0, 0.5) 
    fallbackNode.addChildNode(markerNode)

    fallbackNode.isHidden = true
    ringNode = fallbackNode
    scnView.scene?.rootNode.addChildNode(fallbackNode)
    print("[JewelryAR] ℹ️ using fallback ring with RED marker on top")
  }

  // MARK: - MediaPipe setup

  private func setupMediaPipe() {
    print("[JewelryAR] ℹ️ setupMediaPipe called")
    // The hand_landmarker.task model must be in the app bundle.
    // Copy it into ios/Runner/ or reference via Flutter assets.
    let assetKey = FlutterDartProject.lookupKey(forAsset: "assets/hand_landmarker.task")
    guard let modelPath = Bundle.main.path(forResource: assetKey, ofType: nil) else {
      print("[JewelryAR] ❌ hand_landmarker.task not found at asset key: \(assetKey)")
      return
    }
    print("[JewelryAR] ℹ️ modelPath found: \(modelPath)")

    do {
      let options = HandLandmarkerOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .liveStream
      options.handLandmarkerLiveStreamDelegate = self
      options.numHands = 1
      options.minHandDetectionConfidence = 0.5
      options.minHandPresenceConfidence = 0.5
      options.minTrackingConfidence = 0.5

      handLandmarker = try HandLandmarker(options: options)
      print("[JewelryAR] ✅ MediaPipe HandLandmarker ready")
    } catch {
      print("[JewelryAR] ❌ MediaPipe init failed: \(error)")
    }
  }

  // MARK: - Ring positioning from 3D landmarks
  
  private var frameCounter = 0

  private func updateRingPosition(
    landmarks: [NormalizedLandmark],
    worldLandmarks: [Landmark]
  ) {
    guard let ring = ringNode, let occluder = fingerOccluderNode else {
      return
    }

    // Landmark indices: 0 = wrist, 5 = index MCP, 17 = pinky MCP, 13 = ring MCP, 14 = ring PIP
    guard landmarks.count > 17, worldLandmarks.count > 17 else { return }

    // 1. Estimate distance (Z) from camera.
    let w5 = worldLandmarks[5]
    let w17 = worldLandmarks[17]
    let realDist = sqrt(pow(w5.x - w17.x, 2) + pow(w5.y - w17.y, 2) + pow(w5.z - w17.z, 2))

    let n5 = landmarks[5]
    let n17 = landmarks[17]
    let screenDist = sqrt(pow(n5.x - n17.x, 2) + pow(n5.y - n17.y, 2))

    let fov: Float = 60.0
    let focalLen = 0.5 / tan(fov * .pi / 360.0)
    // Clamp estimatedZ between 10cm and 1.5m to avoid jumps
    let estimatedZ = max(0.1, min(1.5, (realDist * focalLen) / max(screenDist, 1e-4)))

    // 2. Calculate target position
    let n13 = landmarks[13]
    let n14 = landmarks[14]
    // Increased t from 0.30 to 0.45 to move the ring further away from the hand
    let t: Float = 0.3
    let nx = n13.x + (n14.x - n13.x) * t
    let ny = n13.y + (n14.y - n13.y) * t

    let aspect = Float(bounds.width / bounds.height)
    let px = (nx - 0.5) * estimatedZ / focalLen * aspect
    let py = (0.5 - ny) * estimatedZ / focalLen

    let w13 = worldLandmarks[13]
    let w14 = worldLandmarks[14]
    let relativeZ = w13.z + (w14.z - w13.z) * t
    let pz = -estimatedZ + Float(relativeZ)

    // 3. Orientation & Matrix construction
    let dx = w14.x - w13.x
    let dy = -(w14.y - w13.y) // Flip for SceneKit
    let dz = -(w14.z - w13.z) // Flip for SceneKit
    let worldBoneLen = sqrt(dx * dx + dy * dy + dz * dz)

    // We want the ring's "hole" (Y-axis in many models) to align with the finger bone.
    let boneVec = simd_float3(dx, dy, dz)
    let direction = normalize(boneVec)
    
    // Use Middle finger (9) and Ring finger (13) to find the "side" vector of the hand
    let w9 = worldLandmarks[9]
    let sideVec = normalize(simd_float3(w9.x - w13.x, -(w9.y - w13.y), -(w9.z - w13.z)))
    
    // Normal to the finger surface - flipped cross product to point "up" from the back of the hand
    let upVec = normalize(cross(direction, sideVec))
    let rightVec = cross(direction, upVec)
    
    // Construct rotation matrix (Column-major)
    // We assume the ring model's "hole axis" is Y.
    let transform = simd_float4x4(
      simd_float4(rightVec.x, rightVec.y, rightVec.z, 0),
      simd_float4(direction.x, direction.y, direction.z, 0),
      simd_float4(upVec.x, upVec.y, upVec.z, 0),
      simd_float4(px, py, pz, 1)
    )

    // 4. Scale
    // Reducing from 0.60 to 0.53 for a tighter fit.
    let rawScale = worldBoneLen * 0.53
    
    frameCounter += 1
    
    // Apply smoothing to the whole matrix or components
    let targetPos = SCNVector3(px, py, pz)
    
    if hasSmoothedValues {
      smoothedPosition = lerpVec3(smoothedPosition, targetPos, t: smoothingFactor)
      // High-inertia smoothing for scale to prevent "blinking"
      smoothedScale = smoothedScale + (rawScale - smoothedScale) * scaleSmoothingFactor
    } else {
      smoothedPosition = targetPos
      smoothedScale = rawScale
      hasSmoothedValues = true
    }
    
    if frameCounter % 60 == 0 {
       print("[JewelryAR] ✅ Positioning ring. Scaled width: \(smoothedScale * 100)cm")
    }

    ring.simdTransform = transform
    ring.simdScale = simd_float3(smoothedScale, smoothedScale, smoothedScale)
    ring.isHidden = false

    // Occluder: must be slightly smaller than the ring inner radius (which is scale * 0.45)
    occluder.simdTransform = transform
    if let cylinder = occluder.geometry as? SCNCylinder {
      cylinder.radius = CGFloat(smoothedScale * 0.45) 
      cylinder.height = CGFloat(worldBoneLen * 1.8)
    }
    occluder.isHidden = false

    // Optional debug log
    // print("[JewelryAR] Z: \(estimatedZ), Pos: \(px), \(py), \(pz)")
  }

  private func lerpVec3(_ a: SCNVector3, _ b: SCNVector3, t: Float) -> SCNVector3 {
    return SCNVector3(
      a.x + (b.x - a.x) * t,
      a.y + (b.y - a.y) * t,
      a.z + (b.z - a.z) * t
    )
  }

  // MARK: - Send landmarks to Flutter

  private func emitLandmarks(
    landmarks: [NormalizedLandmark],
    worldLandmarks: [Landmark]
  ) {
    guard let sink = eventSink else { return }

    var jointsMap: [Int: [String: Double]] = [:]
    for (i, wl) in worldLandmarks.enumerated() {
      let nl = i < landmarks.count ? landmarks[i] : nil
      jointsMap[i] = [
        "x": Double(nl?.x ?? wl.x),
        "y": Double(nl?.y ?? wl.y),
        "z": Double(wl.z),
      ]
    }

    var eventData: [String: Any] = ["landmarks": jointsMap]
    
    // Add ring transform data if available
    if let ring = ringNode, !ring.isHidden {
      eventData["ringPosition"] = [
        "x": Double(ring.position.x),
        "y": Double(ring.position.y),
        "z": Double(ring.position.z)
      ]
      eventData["ringScale"] = Double(ring.scale.x)
    }

    DispatchQueue.main.async {
      sink(eventData)
    }
  }

  private func hideRing() {
    ringNode?.isHidden = true
    fingerOccluderNode?.isHidden = true
    hasSmoothedValues = false
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension JewelryArView: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let landmarker = handLandmarker else { return }

    let timestampMs = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
    guard timestampMs > lastTimestampMs else { return }
    lastTimestampMs = timestampMs

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    // On iOS, camera buffers are often in .right orientation if not handled.
    // However, since we set videoOrientation = .portrait, .up should be correct.
    let mpImage = try? MPImage(pixelBuffer: pixelBuffer, orientation: .up)
    guard let image = mpImage else { return }

    do {
      try landmarker.detectAsync(image: image, timestampInMilliseconds: timestampMs)
    } catch {
      // Frame processing error – skip silently
    }
  }
}

// MARK: - HandLandmarkerLiveStreamDelegate

extension JewelryArView: HandLandmarkerLiveStreamDelegate {
  func handLandmarker(
    _ handLandmarker: HandLandmarker,
    didFinishDetection result: HandLandmarkerResult?,
    timestampInMilliseconds: Int,
    error: Error?
  ) {
    if let error = error {
      print("[JewelryAR] ❌ detection error: \(error)")
    }

    guard let result = result,
          let firstHand = result.landmarks.first,
          let firstWorld = result.worldLandmarks.first
    else {
      DispatchQueue.main.async { [weak self] in
        self?.hideRing()
      }
      return
    }

    if frameCounter % 60 == 0 {
      print("[JewelryAR] ✅ hand detected")
    }

    // Update 3D ring position on main thread (SceneKit)
    DispatchQueue.main.async { [weak self] in
      self?.updateRingPosition(landmarks: firstHand, worldLandmarks: firstWorld)
    }

    // Stream landmarks back to Flutter
    emitLandmarks(landmarks: firstHand, worldLandmarks: firstWorld)
  }
}

// MARK: - FlutterStreamHandler

extension JewelryArView: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
