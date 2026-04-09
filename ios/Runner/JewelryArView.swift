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

    // Debug overlay on top of everything
    debugOverlay.frame = bounds
    debugOverlay.layer.zPosition = 200
    addSubview(debugOverlay)
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
    // Thinner band: pipeRadius 0.06 (was 0.10)
    let torus = SCNTorus(ringRadius: 0.40, pipeRadius: 0.06)
    let bandMaterial = SCNMaterial()
    bandMaterial.lightingModel = .physicallyBased
    bandMaterial.diffuse.contents = UIColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1.0)
    bandMaterial.metalness.contents = 0.95
    bandMaterial.roughness.contents = 0.15
    bandMaterial.isDoubleSided = true
    torus.materials = [bandMaterial]

    let fallbackNode = SCNNode(geometry: torus)

    // ── Diamond / gem on top (Z+ in model space = dorsal side of finger) ──
    // Multi-faceted gem using SCNSphere with low segment count for faceted look
    let gemRadius: CGFloat = 0.12
    let gemGeo = SCNSphere(radius: gemRadius)
    gemGeo.segmentCount = 8  // Low segment count = faceted diamond look

    let gemMat = SCNMaterial()
    gemMat.lightingModel = .physicallyBased
    // Slightly blue-white diamond color with high transparency/sparkle
    gemMat.diffuse.contents = UIColor(red: 0.92, green: 0.95, blue: 1.0, alpha: 1.0)
    gemMat.metalness.contents = 0.05
    gemMat.roughness.contents = 0.02  // Very smooth = sparkly reflections
    gemMat.transparency = 0.85
    gemMat.transparencyMode = .dualLayer
    gemMat.fresnelExponent = 3.0  // Strong edge reflections like a real gem
    gemMat.specular.contents = UIColor.white
    gemMat.isDoubleSided = true
    gemGeo.materials = [gemMat]

    let gemNode = SCNNode(geometry: gemGeo)
    // Position on top of the band (Z+ = dorsal/top side)
    gemNode.position = SCNVector3(0, 0, 0.40)
    // Slightly squash vertically to make it look more like a cut gem
    gemNode.scale = SCNVector3(1.0, 1.0, 0.7)
    fallbackNode.addChildNode(gemNode)

    // Small gold prong holders around the gem
    for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
      let prong = SCNCylinder(radius: 0.015, height: 0.10)
      let prongMat = SCNMaterial()
      prongMat.lightingModel = .physicallyBased
      prongMat.diffuse.contents = UIColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1.0)
      prongMat.metalness.contents = 0.95
      prongMat.roughness.contents = 0.15
      prong.materials = [prongMat]

      let prongNode = SCNNode(geometry: prong)
      let rad = Float(angle) * Float.pi / 180.0
      let prongDist: Float = Float(gemRadius) * 0.8
      prongNode.position = SCNVector3(
        prongDist * cos(rad),
        prongDist * sin(rad),
        Float(0.40)
      )
      // Align prong along Z axis (pointing up from band)
      prongNode.eulerAngles = SCNVector3(Float.pi / 2.0, 0, 0)
      fallbackNode.addChildNode(prongNode)
    }

    fallbackNode.isHidden = true
    ringNode = fallbackNode
    scnView.scene?.rootNode.addChildNode(fallbackNode)
    print("[JewelryAR] ℹ️ using fallback ring with diamond on top")
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

  // MARK: - Ring positioning (world-screen hybrid approach)
  //
  // Position from SCREEN landmarks (with resizeAspectFill crop correction).
  // Scale from WORLD finger width × screen-space pixels-per-meter ratio
  //   → rotation-invariant: world gives true finger width, screen gives perspective.
  // Orientation from WORLD landmarks (3D finger tilt).
  //
  // The ring lives at a fixed Z plane in SceneKit; apparent size changes
  // come from the screen-space reference scaling with distance.

  private var frameCounter = 0

  // Fixed depth plane – ring always sits here; perspective from screen coords.
  private let fixedZ: Float = -0.5

  private func updateRingPosition(
    landmarks: [NormalizedLandmark],
    worldLandmarks: [Landmark],
    isLeftHand: Bool
  ) {
    guard let ring = ringNode, let occluder = fingerOccluderNode else { return }
    guard landmarks.count > 17, worldLandmarks.count > 17 else { return }
    guard bounds.width > 0, bounds.height > 0 else { return }

    framesWithoutDetection = 0
    frameCounter += 1

    let now = CACurrentMediaTime()

    // ── Visible area at the fixed Z plane ──
    let aspect = Float(bounds.width / bounds.height)
    let halfTan = tanf(Float.pi / 6.0) // tan(30°) for 60° FOV SceneKit camera
    let visH = 2.0 * abs(fixedZ) * halfTan  // ≈ 0.577 scene units
    let visW = visH * aspect

    // ── Crop correction for resizeAspectFill ──
    // Camera preset 1280×720 → portrait 720×1280. The preview may crop width.
    let imageAspect: Float = 720.0 / 1280.0
    let viewAspect = Float(bounds.width / bounds.height)
    let cropX: Float = imageAspect > viewAspect ? imageAspect / viewAspect : 1.0
    let cropY: Float = viewAspect > imageAspect ? viewAspect / imageAspect : 1.0

    // ── 1. POSITION from screen landmarks (crop-corrected) ──
    let t: Float = 0.58
    let nx = landmarks[13].x + (landmarks[14].x - landmarks[13].x) * t
    let ny = landmarks[13].y + (landmarks[14].y - landmarks[13].y) * t
    let rawX = (nx - 0.5) * visW * cropX
    let rawY = (0.5 - ny) * visH * cropY

    // ── 2. SCALE: World-screen hybrid (rotation-invariant finger width) ──
    // World landmarks give true 3D distances in metres, unaffected by viewing angle.
    // Screen landmarks provide correct perspective scaling for the current distance.
    // Combined: worldFingerWidth × (screenRef / worldRef) = finger width in scene units.
    func w3(_ i: Int) -> simd_float3 {
      simd_float3(worldLandmarks[i].x, worldLandmarks[i].y, worldLandmarks[i].z)
    }
    func s2(_ i: Int) -> simd_float2 {
      let sx = (landmarks[i].x - 0.5) * visW * cropX
      let sy = (0.5 - landmarks[i].y) * visH * cropY
      return simd_float2(sx, sy)
    }

    // ── Finger width from inter-MCP gap ──
    let worldMCPGap = distance(w3(9), w3(13))
    guard worldMCPGap > 0.001 else { return }
    let worldFingerWidth = worldMCPGap * 0.85

    // Scene-units-per-metre from multiple reference pairs, weighted by screen visibility
    let refs: [(w: Float, s: Float)] = [
      (distance(w3(0), w3(9)),  distance(s2(0), s2(9))),   // wrist → middle MCP
      (distance(w3(5), w3(17)), distance(s2(5), s2(17))),  // index MCP → pinky MCP
      (distance(w3(0), w3(5)),  distance(s2(0), s2(5))),   // wrist → index MCP
      (distance(w3(0), w3(17)), distance(s2(0), s2(17))),  // wrist → pinky MCP
    ]
    var wSum: Float = 0, wTot: Float = 0
    for r in refs where r.w > 0.005 {
      let weight = r.s * r.s  // heavier weight for more visible (less foreshortened) pairs
      wSum += weight * (r.s / r.w)
      wTot += weight
    }
    guard wTot > 0 else { return }
    let scenePerMetre = wSum / wTot

    // World-screen hybrid (rotation-invariant but may undersize on face-on views)
    let hybridFingerWidth = worldFingerWidth * scenePerMetre
    // Direct screen-space MCP gap (accurate when hand is flat to camera)
    let screenMCPGap = distance(s2(9), s2(13))
    let screenFingerWidth = screenMCPGap * 0.85
    // Use the larger: screen is accurate face-on, hybrid is better when rotated
    let fingerWidthScene = max(hybridFingerWidth, screenFingerWidth)
    let rawScale = max(fingerWidthScene / 0.68, 0.003)  // 0.68 = torus inner diameter

    // ── 3. ORIENTATION ──
    // toSK helper for world landmarks:
    //   MediaPipe Y-down → SceneKit Y-up (negate Y)
    //   MediaPipe Z+ away from camera → SceneKit Z+ toward camera (negate Z)
    func toSK(_ l: Landmark) -> simd_float3 {
      simd_float3(l.x, -l.y, -l.z)
    }

    // A) DIRECTION (torus axis = along finger): from WORLD bone direction (full 3D)
    let boneWorld = toSK(worldLandmarks[14]) - toSK(worldLandmarks[13])
    let boneDirLen = simd_length(boneWorld)
    guard boneDirLen > 1e-6 else { return }
    let direction = normalize(boneWorld)

    // Palm normal from WORLD landmarks (only source of depth/facing info)
    let sk0 = toSK(worldLandmarks[0])
    let sk5 = toSK(worldLandmarks[5])
    let sk9 = toSK(worldLandmarks[9])
    let sk13 = toSK(worldLandmarks[13])
    let sk17 = toSK(worldLandmarks[17])

    let crosses = [
      cross(sk5 - sk0, sk17 - sk0),
      cross(sk5 - sk0, sk13 - sk0),
      cross(sk9 - sk0, sk17 - sk0),
    ]
    var avgPalmCross = simd_float3.zero
    for c in crosses {
      let len = simd_length(c)
      if len > 1e-6 { avgPalmCross += c / len }
    }
    guard simd_length(avgPalmCross) > 1e-6 else { return }

    var palmNormal = normalize(avgPalmCross)
    // For left hand, cross product already points toward dorsal.
    // For right hand, need to negate.
    if !isLeftHand { palmNormal = -palmNormal }

    // Project dorsal-normal ⊥ to finger direction → upVec
    let projNormal = palmNormal - dot(palmNormal, direction) * direction
    let projLen = simd_length(projNormal)
    let upVec: simd_float3
    if projLen > 0.1 {
      upVec = projNormal / projLen
    } else {
      upVec = normalize(simd_float3(-direction.y, direction.x, 0))
    }
    let rightVec = normalize(cross(direction, upVec))
    let targetRotation = simd_quaternion(simd_float3x3(rightVec, direction, upVec))

    if frameCounter % 30 == 0 {
      print("[JewelryAR] 🔍 palmN=(\(String(format: "%.2f,%.2f,%.2f", palmNormal.x, palmNormal.y, palmNormal.z))) upVec=(\(String(format: "%.2f,%.2f,%.2f", upVec.x, upVec.y, upVec.z))) projLen=\(String(format: "%.3f", projLen)) isLeft=\(isLeftHand)")
    }

    // Bail if quaternion is invalid (NaN)
    guard targetRotation.real.isFinite else { return }

    // ── 4. SMOOTHING (One-Euro for pos/scale, slerp for rotation) ──
    let smoothX = filterPosX.filter(rawX, at: now)
    let smoothY = filterPosY.filter(rawY, at: now)
    let smoothScale = filterScale.filter(rawScale, at: now)

    if hasSmoothedValues {
      // Ensure shortest-path slerp: negate target if it's in the opposite hemisphere.
      // This prevents the ring from taking the "long way around" (180° flip).
      var target = targetRotation
      if simd_dot(smoothedRotation, target) < 0 {
        target = simd_quatf(ix: -target.imag.x, iy: -target.imag.y,
                            iz: -target.imag.z, r: -target.real)
      }
      smoothedRotation = simd_slerp(smoothedRotation, target, rotationAlpha)
    } else {
      smoothedRotation = targetRotation
      hasSmoothedValues = true
    }

    if frameCounter % 30 == 0 {
      print("[JewelryAR] 📍 pos=(\(String(format: "%.4f", smoothX)), \(String(format: "%.4f", smoothY))) scale=\(String(format: "%.4f", smoothScale)) bounds=\(bounds.width)x\(bounds.height)")
    }

    // ── 5. APPLY ──
    ring.position = SCNVector3(smoothX, smoothY, fixedZ)
    ring.simdOrientation = smoothedRotation
    ring.simdScale = simd_float3(repeating: smoothScale)
    ring.isHidden = false

    occluder.position = ring.position
    occluder.simdOrientation = smoothedRotation
    if let cyl = occluder.geometry as? SCNCylinder {
      // Radius must nearly fill the torus interior (ringRadius=0.40) so the
      // back half of the ring is hidden behind the "finger" depth mask.
      cyl.radius = CGFloat(smoothScale * 0.38)
      cyl.height = CGFloat(smoothScale * 2.0)
    }
    occluder.isHidden = false

    // ── 6. DEBUG OVERLAY ──
    var debugData = DebugOverlayData()
    debugData.landmarks = landmarks.map { (CGFloat($0.x), CGFloat($0.y)) }
    debugData.ringNorm = CGPoint(x: CGFloat(nx), y: CGFloat(ny))
    debugData.palmNormal3D = palmNormal
    debugData.ringQuaternion = smoothedRotation
    debugData.palmCenter = CGPoint(
      x: CGFloat((landmarks[0].x + landmarks[5].x + landmarks[9].x + landmarks[13].x + landmarks[17].x) / 5.0),
      y: CGFloat((landmarks[0].y + landmarks[5].y + landmarks[9].y + landmarks[13].y + landmarks[17].y) / 5.0)
    )
    debugData.mcpWidth = worldFingerWidth
    debugData.boneMaxWidth = 0  // no cap
    debugData.hybridFW = hybridFingerWidth
    debugData.screenFW = screenFingerWidth
    debugData.finalScale = smoothScale
    debugData.isCapped = false
    debugData.upVec3D = upVec
    debugData.direction3D = direction
    debugData.rightVec3D = rightVec
    debugData.smoothedScale = smoothScale
    // Bone 3D: world finger direction — now same as ring direction (full 3D)
    debugData.boneDir3D = direction
    // Bone dorsal: palmNormal projected ⊥ to bone direction (same as upVec now)
    debugData.boneDorsalDir3D = upVec
    // Angles for comparison
    debugData.boneAngleScreen = atan2(direction.y, direction.x) * 180.0 / .pi
    debugData.boneTiltZ = direction.z
    debugData.ringAngleScreen = atan2(direction.y, direction.x) * 180.0 / .pi
    debugData.ringTiltZ = direction.z
    debugOverlay.data = debugData
    debugOverlay.setNeedsDisplay()
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
    framesWithoutDetection += 1

    // Grace period: keep ring visible for a few frames to avoid flicker on momentary loss
    if framesWithoutDetection <= gracePeriodFrames {
      return
    }

    ringNode?.isHidden = true
    fingerOccluderNode?.isHidden = true
    // Reset all filter state so re-acquisition starts fresh
    hasSmoothedValues = false
    filterPosX.reset()
    filterPosY.reset()
    filterScale.reset()
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
          let firstWorld = result.worldLandmarks.first,
          let handedness = result.handedness.first?.first
    else {
      DispatchQueue.main.async { [weak self] in
        self?.hideRing()
      }
      return
    }

    let isLeftHand = handedness.categoryName == "Left"

    if frameCounter % 60 == 0 {
      print("[JewelryAR] ✅ \(handedness.categoryName) hand detected")
    }

    // Update 3D ring position on main thread (SceneKit)
    DispatchQueue.main.async { [weak self] in
      self?.updateRingPosition(landmarks: firstHand, worldLandmarks: firstWorld, isLeftHand: isLeftHand)
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

// MARK: - One-Euro Filter
// Adaptive low-pass filter: heavy smoothing when signal is stable,
// fast response when signal changes rapidly. Ideal for hand tracking.
// Reference: Casiez et al. "1€ Filter" (CHI 2012)

struct OneEuroFilter {
  var minCutoff: Float  // Minimum smoothing cutoff frequency (Hz). Lower = smoother when still.
  var beta: Float       // Speed coefficient. Higher = more responsive to fast movements.
  private let dCutoff: Float = 1.0

  private var xPrev: Float?
  private var dxPrev: Float = 0
  private var lastTime: Double = 0

  init(minCutoff: Float, beta: Float) {
    self.minCutoff = minCutoff
    self.beta = beta
  }

  mutating func filter(_ x: Float, at time: Double) -> Float {
    guard let prev = xPrev else {
      xPrev = x
      lastTime = time
      return x
    }

    let dt = max(Float(time - lastTime), 1.0 / 120.0) // floor at 120 fps
    lastTime = time

    // Smoothed derivative
    let dx = (x - prev) / dt
    let aDx = alpha(dt: dt, cutoff: dCutoff)
    dxPrev = aDx * dx + (1 - aDx) * dxPrev

    // Adaptive cutoff: rises with speed
    let cutoff = minCutoff + beta * abs(dxPrev)
    let a = alpha(dt: dt, cutoff: cutoff)

    let result = a * x + (1 - a) * prev
    xPrev = result
    return result
  }

  mutating func reset() {
    xPrev = nil
    dxPrev = 0
  }

  private func alpha(dt: Float, cutoff: Float) -> Float {
    let tau = 1.0 / (2.0 * Float.pi * cutoff)
    return 1.0 / (1.0 + tau / dt)
  }
}

// MARK: - Debug Overlay Data & View

struct DebugOverlayData {
  var landmarks: [(x: CGFloat, y: CGFloat)] = []  // normalized 0-1
  var ringNorm: CGPoint = .zero                     // ring position normalized
  var palmCenter: CGPoint = .zero                   // palm center normalized
  var palmNormal3D: simd_float3 = .zero             // palm normal in SceneKit space
  var ringQuaternion: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
  var mcpWidth: Float = 0
  var boneMaxWidth: Float = 0
  var hybridFW: Float = 0
  var screenFW: Float = 0
  var finalScale: Float = 0
  var isCapped: Bool = false
  var upVec3D: simd_float3 = .zero
  var direction3D: simd_float3 = .zero    // finger direction (ring Y axis) — SCREEN based
  var rightVec3D: simd_float3 = .zero     // ring lateral axis (ring X axis)
  var smoothedScale: Float = 0            // smoothed ring scale for ring outline size
  // Bone 3D data (world landmarks in SceneKit space) for comparison
  var boneDir3D: simd_float3 = .zero      // world finger bone direction (13→14)
  var boneDorsalDir3D: simd_float3 = .zero // palmNormal projected ⊥ bone (where dorsal faces on bone)
  var boneAngleScreen: Float = 0          // bone angle on screen (atan2)
  var boneTiltZ: Float = 0                // bone Z tilt (how much finger points toward/away camera)
  var ringAngleScreen: Float = 0          // ring direction angle on screen
  var ringTiltZ: Float = 0               // ring Z tilt (always 0 for screen-based direction)
}

class DebugOverlayView: UIView {
  var data = DebugOverlayData()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError() }

  // Convert normalized MediaPipe coords → UIView points (resizeAspectFill)
  private func toView(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
    let imgW: CGFloat = 720, imgH: CGFloat = 1280  // portrait after rotation
    let scale = max(bounds.width / imgW, bounds.height / imgH)
    let projW = imgW * scale, projH = imgH * scale
    let offX = (projW - bounds.width) / 2
    let offY = (projH - bounds.height) / 2
    return CGPoint(x: nx * projW - offX, y: ny * projH - offY)
  }

  // Finger color coding
  private func colorForLandmark(_ i: Int) -> UIColor {
    switch i {
    case 0:      return .white          // wrist
    case 1...4:  return .systemRed      // thumb
    case 5...8:  return .systemOrange   // index
    case 9...12: return .systemYellow   // middle
    case 13...16: return .systemGreen   // ring
    case 17...20: return .systemBlue    // pinky
    default:     return .white
    }
  }

  // Hand bone connections (same as MediaPipe skeleton)
  private let bones: [(Int, Int)] = [
    (0,1),(0,5),(0,9),(0,13),(0,17),     // wrist → finger bases
    (5,9),(9,13),(13,17),                 // transverse metacarpal
    (1,2),(2,3),(3,4),                    // thumb
    (5,6),(6,7),(7,8),                    // index
    (9,10),(10,11),(11,12),               // middle
    (13,14),(14,15),(15,16),              // ring
    (17,18),(18,19),(19,20),              // pinky
  ]

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    let lm = data.landmarks
    guard lm.count >= 21 else { return }

    let pts = lm.enumerated().map { (i, l) in toView(l.x, l.y) }

    // ── 1. Palm surface tint (palm=red, dorsal=green) ──
    let palmZ = data.palmNormal3D.z
    let tintColor: UIColor = palmZ > 0
      ? UIColor.systemGreen.withAlphaComponent(0.15)
      : UIColor.systemRed.withAlphaComponent(0.15)
    let palmIndices = [0, 5, 9, 13, 17]  // wrist → index MCP → middle → ring → pinky
    ctx.setFillColor(tintColor.cgColor)
    ctx.move(to: pts[palmIndices[0]])
    for idx in palmIndices.dropFirst() { ctx.addLine(to: pts[idx]) }
    ctx.closePath()
    ctx.fillPath()

    // ── 2. Skeleton lines ──
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.4).cgColor)
    for (a, b) in bones where a < pts.count && b < pts.count {
      ctx.move(to: pts[a])
      ctx.addLine(to: pts[b])
    }
    ctx.strokePath()

    // ── 3. Ring finger bone highlight (13→14, thick green) ──
    ctx.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(4.0)
    ctx.move(to: pts[13])
    ctx.addLine(to: pts[14])
    ctx.strokePath()

    // Finger width perpendicular lines at ring position
    let ringPt = toView(data.ringNorm.x, data.ringNorm.y)
    let dir2D = data.direction3D  // SceneKit space (Y up)
    let dir2Dlen = CGFloat(sqrtf(dir2D.x * dir2D.x + dir2D.y * dir2D.y))
    if dir2Dlen > 0.01 {
      // Perpendicular to finger direction in screen space
      let perpX = CGFloat(-dir2D.y) / dir2Dlen  // rotate 90°
      let perpY = CGFloat(dir2D.x) / dir2Dlen
      // Scale: fingerWidth in scene units → approximate pixels (use distance between 13 and 14 on screen as reference)
      let boneLenPx = hypot(pts[14].x - pts[13].x, pts[14].y - pts[13].y)
      let widthPx = boneLenPx * 0.6  // approximate finger width relative to bone length
      let wA = CGPoint(x: ringPt.x + perpX * widthPx / 2, y: ringPt.y - perpY * widthPx / 2)
      let wB = CGPoint(x: ringPt.x - perpX * widthPx / 2, y: ringPt.y + perpY * widthPx / 2)
      ctx.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.7).cgColor)
      ctx.setLineWidth(2.0)
      ctx.move(to: wA)
      ctx.addLine(to: wB)
      ctx.strokePath()
    }

    // ── 4. Landmark dots ──
    for (i, pt) in pts.enumerated() {
      let r: CGFloat = i == 13 || i == 14 ? 6 : 4
      let color = colorForLandmark(i)
      ctx.setFillColor(color.cgColor)
      ctx.fillEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
      ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor)
      ctx.setLineWidth(1.0)
      ctx.strokeEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
    }

    // ── 5. Palm normal arrow (cyan) ──
    let palmPt = toView(data.palmCenter.x, data.palmCenter.y)
    let nrm = data.palmNormal3D
    let arrowLen: CGFloat = 60
    let nLen = CGFloat(sqrtf(nrm.x * nrm.x + nrm.y * nrm.y))
    if nLen > 0.01 {
      let ndx = CGFloat(nrm.x) / nLen * arrowLen
      let ndy = CGFloat(nrm.y) / nLen * arrowLen
      let tip = CGPoint(x: palmPt.x + ndx, y: palmPt.y - ndy)
      ctx.setStrokeColor(UIColor.cyan.cgColor)
      ctx.setLineWidth(3.0)
      ctx.move(to: palmPt)
      ctx.addLine(to: tip)
      ctx.strokePath()
      ctx.setFillColor(UIColor.cyan.cgColor)
      ctx.fillEllipse(in: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8))
    }

    // ── 6. Ring orientation axes ──
    let q = data.ringQuaternion
    let axisLen: CGFloat = 40
    let axes: [(simd_float3, UIColor, String)] = [
      (simd_float3(1, 0, 0), .systemRed,   "R"),  // rightVec (X)
      (simd_float3(0, 1, 0), .systemGreen, "D"),  // direction/finger (Y)
      (simd_float3(0, 0, 1), .systemBlue,  "U"),  // upVec/dorsal (Z)
    ]
    for (axisDir, color, label) in axes {
      let rotated = q.act(axisDir)
      let dx = CGFloat(rotated.x) * axisLen
      let dy = CGFloat(rotated.y) * axisLen
      let end = CGPoint(x: ringPt.x + dx, y: ringPt.y - dy)
      ctx.setStrokeColor(color.cgColor)
      ctx.setLineWidth(2.5)
      ctx.move(to: ringPt)
      ctx.addLine(to: end)
      ctx.strokePath()
      // Axis label at tip
      let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 10),
        .foregroundColor: color,
      ]
      (label as NSString).draw(at: CGPoint(x: end.x + 2, y: end.y - 12), withAttributes: labelAttrs)
    }

    // ── 7. Diamond direction indicator (yellow diamond shape at upVec tip) ──
    let upRotated = q.act(simd_float3(0, 0, 1))
    let diamondDist: CGFloat = axisLen * 1.3
    let diamondCenter = CGPoint(
      x: ringPt.x + CGFloat(upRotated.x) * diamondDist,
      y: ringPt.y - CGFloat(upRotated.y) * diamondDist
    )
    let ds: CGFloat = 7  // diamond half-size
    ctx.setFillColor(UIColor.yellow.withAlphaComponent(0.9).cgColor)
    ctx.move(to: CGPoint(x: diamondCenter.x, y: diamondCenter.y - ds))      // top
    ctx.addLine(to: CGPoint(x: diamondCenter.x + ds, y: diamondCenter.y))    // right
    ctx.addLine(to: CGPoint(x: diamondCenter.x, y: diamondCenter.y + ds))    // bottom
    ctx.addLine(to: CGPoint(x: diamondCenter.x - ds, y: diamondCenter.y))    // left
    ctx.closePath()
    ctx.fillPath()
    ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.5).cgColor)
    ctx.setLineWidth(1.0)
    ctx.move(to: CGPoint(x: diamondCenter.x, y: diamondCenter.y - ds))
    ctx.addLine(to: CGPoint(x: diamondCenter.x + ds, y: diamondCenter.y))
    ctx.addLine(to: CGPoint(x: diamondCenter.x, y: diamondCenter.y + ds))
    ctx.addLine(to: CGPoint(x: diamondCenter.x - ds, y: diamondCenter.y))
    ctx.closePath()
    ctx.strokePath()

    // ── 8. Projected ring ellipse (magenta, dashed) ──
    // Project a circle in ring's local XZ plane onto screen
    let segments = 24
    // Ring radius in pixels: use finger width line (yellow) as reference
    // The ring should wrap around the finger, so radius ≈ half of finger width
    let boneLenPxRef = hypot(pts[14].x - pts[13].x, pts[14].y - pts[13].y)
    let ringRadPx: CGFloat = boneLenPxRef * 0.35  // ~35% of bone length ≈ finger radius

    ctx.setStrokeColor(UIColor.magenta.withAlphaComponent(0.7).cgColor)
    ctx.setLineWidth(2.0)
    ctx.setLineDash(phase: 0, lengths: [6, 4])

    var ellipsePoints: [CGPoint] = []
    for i in 0...segments {
      let angle = Float(i) * (2.0 * .pi / Float(segments))
      // Circle in ring's local XZ plane (Y = finger direction = torus axis)
      let localPt = simd_float3(cosf(angle), 0, sinf(angle))
      let rotated = q.act(localPt)
      // Project to screen: use X directly, flip Y for screen coords
      let screenPt = CGPoint(
        x: ringPt.x + CGFloat(rotated.x) * ringRadPx,
        y: ringPt.y - CGFloat(rotated.y) * ringRadPx
      )
      ellipsePoints.append(screenPt)
    }

    if let first = ellipsePoints.first {
      ctx.move(to: first)
      for pt in ellipsePoints.dropFirst() { ctx.addLine(to: pt) }
      ctx.strokePath()
    }
    ctx.setLineDash(phase: 0, lengths: [])  // reset dash

    // ── 9. Palm/Dorsal gauge (top-center) ──
    let gaugeW: CGFloat = 180
    let gaugeH: CGFloat = 24
    let gaugeX = (bounds.width - gaugeW) / 2
    let gaugeY: CGFloat = 56  // below status bar

    // Background bar
    let gaugeRect = CGRect(x: gaugeX, y: gaugeY, width: gaugeW, height: gaugeH)
    let gaugeBg = UIBezierPath(roundedRect: gaugeRect, cornerRadius: 4)
    ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
    ctx.addPath(gaugeBg.cgPath)
    ctx.fillPath()

    // Left half red gradient, right half green gradient
    let halfW = gaugeW / 2
    // Red fill (left side)
    let redRect = CGRect(x: gaugeX + 2, y: gaugeY + 2, width: halfW - 2, height: gaugeH - 4)
    ctx.setFillColor(UIColor.systemRed.withAlphaComponent(0.25).cgColor)
    ctx.fill(redRect)
    // Green fill (right side)
    let greenRect = CGRect(x: gaugeX + halfW, y: gaugeY + 2, width: halfW - 2, height: gaugeH - 4)
    ctx.setFillColor(UIColor.systemGreen.withAlphaComponent(0.25).cgColor)
    ctx.fill(greenRect)

    // Center line
    ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
    ctx.setLineWidth(1.0)
    ctx.move(to: CGPoint(x: gaugeX + halfW, y: gaugeY + 2))
    ctx.addLine(to: CGPoint(x: gaugeX + halfW, y: gaugeY + gaugeH - 2))
    ctx.strokePath()

    // Marker dot at palmNormal.z position (clamped -1..1 → 0..gaugeW)
    let clampedZ = max(-1, min(1, CGFloat(palmZ)))
    let markerX = gaugeX + halfW + clampedZ * halfW
    let markerColor: UIColor = palmZ > 0 ? .systemGreen : .systemRed
    ctx.setFillColor(markerColor.cgColor)
    ctx.fillEllipse(in: CGRect(x: markerX - 6, y: gaugeY + gaugeH / 2 - 6, width: 12, height: 12))
    ctx.setStrokeColor(UIColor.white.cgColor)
    ctx.setLineWidth(1.5)
    ctx.strokeEllipse(in: CGRect(x: markerX - 6, y: gaugeY + gaugeH / 2 - 6, width: 12, height: 12))

    // Labels
    let smallAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.boldSystemFont(ofSize: 10),
      .foregroundColor: UIColor.white,
    ]
    ("PALM" as NSString).draw(at: CGPoint(x: gaugeX + 4, y: gaugeY + 4), withAttributes: smallAttrs)
    ("DORSAL" as NSString).draw(at: CGPoint(x: gaugeX + gaugeW - 48, y: gaugeY + 4), withAttributes: smallAttrs)

    // Z value below gauge
    let zStr = String(format: "palmN.z: %+.2f", palmZ)
    let zAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium),
      .foregroundColor: markerColor,
    ]
    let zSize = (zStr as NSString).size(withAttributes: zAttrs)
    (zStr as NSString).draw(
      at: CGPoint(x: (bounds.width - zSize.width) / 2, y: gaugeY + gaugeH + 2),
      withAttributes: zAttrs
    )

    // ── 10. Visual 3D gizmos: BONE vs RING side by side ──
    // Two mini coordinate frames at bottom of screen for direct visual comparison
    // Isometric-ish projection: X→right, Y→up, Z shown as diagonal + depth cues

    let gizmoR: CGFloat = 55          // arrow length
    let gizmoPad: CGFloat = 20
    let gizmoY = bounds.height - 140  // vertical position
    let gizmoBoneCenter = CGPoint(x: bounds.width * 0.25, y: gizmoY)
    let gizmoRingCenter = CGPoint(x: bounds.width * 0.75, y: gizmoY)

    // Isometric projection: 3D vec → 2D screen point (relative to center)
    // Z is shown as diagonal (upper-right = toward camera Z+, lower-left = away Z-)
    func isoProject(_ v: simd_float3, len: CGFloat) -> CGPoint {
      let sx = CGFloat(v.x) + CGFloat(v.z) * 0.35
      let sy = CGFloat(v.y) + CGFloat(v.z) * 0.35
      let sLen = CGFloat(sqrtf(Float(sx * sx + sy * sy)))
      if sLen < 0.01 { return .zero }
      return CGPoint(x: sx / sLen * len, y: -sy / sLen * len)  // -Y for screen coords
    }

    // Draw a single 3D arrow with depth cues
    func drawGizmoArrow(_ center: CGPoint, _ vec: simd_float3, _ color: UIColor,
                        _ label: String, _ arrowLen: CGFloat, dashed: Bool = false) {
      let proj = isoProject(vec, len: arrowLen)
      let tip = CGPoint(x: center.x + proj.x, y: center.y + proj.y)

      // Thickness based on how much the vector is in XY vs Z
      let xyMag = CGFloat(sqrtf(vec.x * vec.x + vec.y * vec.y))
      let lineW: CGFloat = max(1.5, min(4.0, xyMag * 4.0))

      // Alpha: dimmer if pointing away from camera
      let alpha: CGFloat = vec.z < -0.3 ? 0.4 : 0.9

      ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
      ctx.setLineWidth(lineW)
      if dashed { ctx.setLineDash(phase: 0, lengths: [5, 3]) }
      ctx.move(to: center)
      ctx.addLine(to: tip)
      ctx.strokePath()
      if dashed { ctx.setLineDash(phase: 0, lengths: []) }

      // Arrowhead triangle
      let arrowSize: CGFloat = 6
      let dx = tip.x - center.x, dy = tip.y - center.y
      let dLen = hypot(dx, dy)
      if dLen > 1 {
        let ux = dx / dLen, uy = dy / dLen
        let px = -uy, py = ux  // perpendicular
        let base = CGPoint(x: tip.x - ux * arrowSize, y: tip.y - uy * arrowSize)
        ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: base.x + px * arrowSize * 0.5,
                                y: base.y + py * arrowSize * 0.5))
        ctx.addLine(to: CGPoint(x: base.x - px * arrowSize * 0.5,
                                y: base.y - py * arrowSize * 0.5))
        ctx.closePath()
        ctx.fillPath()
      }

      // Z depth indicator at tip
      let zStr = String(format: "%@ z%+.1f", label, vec.z)
      let lAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 9),
        .foregroundColor: color.withAlphaComponent(alpha),
      ]
      (zStr as NSString).draw(at: CGPoint(x: tip.x + 3, y: tip.y - 10), withAttributes: lAttrs)
    }

    // ── Gizmo backgrounds ──
    for (center, title) in [(gizmoBoneCenter, "BONE 3D"), (gizmoRingCenter, "RING")] {
      // Circle background
      let bgR = gizmoR + 20
      ctx.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
      ctx.fillEllipse(in: CGRect(x: center.x - bgR, y: center.y - bgR,
                                 width: bgR * 2, height: bgR * 2))
      ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
      ctx.setLineWidth(1.0)
      ctx.strokeEllipse(in: CGRect(x: center.x - bgR, y: center.y - bgR,
                                   width: bgR * 2, height: bgR * 2))
      // Title
      let tAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 11),
        .foregroundColor: UIColor.white,
      ]
      let tSize = (title as NSString).size(withAttributes: tAttrs)
      (title as NSString).draw(
        at: CGPoint(x: center.x - tSize.width / 2, y: center.y - bgR - 16),
        withAttributes: tAttrs)
      // Center dot
      ctx.setFillColor(UIColor.white.withAlphaComponent(0.5).cgColor)
      ctx.fillEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
    }

    // ── BONE gizmo (left) — world 3D from landmarks ──
    let bd = data.boneDir3D
    let bdd = data.boneDorsalDir3D
    let boneLateral = simd_length(cross(bd, bdd)) > 0.1
      ? normalize(cross(bd, bdd)) : simd_float3(1, 0, 0)

    drawGizmoArrow(gizmoBoneCenter, bd,  .systemGreen,  "dir", gizmoR)      // finger direction
    drawGizmoArrow(gizmoBoneCenter, bdd, .systemBlue,   "drs", gizmoR * 0.8) // dorsal
    drawGizmoArrow(gizmoBoneCenter, boneLateral, .systemRed, "lat", gizmoR * 0.6) // lateral

    // ── RING gizmo (right) — what's actually applied ──
    let rd = data.direction3D
    let ru = data.upVec3D
    let rr = data.rightVec3D

    drawGizmoArrow(gizmoRingCenter, rd, .systemGreen, "dir", gizmoR)       // ring Y (finger)
    drawGizmoArrow(gizmoRingCenter, ru, .systemBlue,  "up",  gizmoR * 0.8) // ring Z (diamond)
    drawGizmoArrow(gizmoRingCenter, rr, .systemRed,   "R",   gizmoR * 0.6) // ring X (lateral)

    // ── Minimal stats below gizmos ──
    let pn = data.palmNormal3D
    let sideLabel = pn.z > 0 ? "DORSAL" : "PALM"
    let statsStr = String(format: "Palm Z: %+.2f [%@]  scale: %.3f  Δang: %+.1f°",
      pn.z, sideLabel, data.finalScale,
      data.ringAngleScreen - data.boneAngleScreen)
    let sAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium),
      .foregroundColor: UIColor.white,
    ]
    let sSize = (statsStr as NSString).size(withAttributes: sAttrs)
    let statsX = (bounds.width - sSize.width) / 2
    let statsY = gizmoY + gizmoR + 30
    // Background
    ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
    ctx.fill(CGRect(x: statsX - 6, y: statsY - 2, width: sSize.width + 12, height: sSize.height + 4))
    (statsStr as NSString).draw(at: CGPoint(x: statsX, y: statsY), withAttributes: sAttrs)
  }
}
