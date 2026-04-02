import UIKit
import ARKit

// MARK: - Flutter View Factory
class RingARViewFactory: NSObject, FlutterPlatformViewFactory {
    private var onViewCreated: ((RingARView) -> Void)?
    
    init(onViewCreated: @escaping (RingARView) -> Void) {
        self.onViewCreated = onViewCreated
        super.init()
    }
    
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        print("[RingAR] 🏭 Factory: Tworzę nowy RingARView")
        let view = RingARView(frame: frame)
        onViewCreated?(view)
        return view
    }
    
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec()
    }
}

// MARK: - Native ARView
class RingARView: UIView, ARSessionDelegate {
    
    private var arView: ARSCNView!
    private var session = ARSession()
    private var debugGloveEnabled: Bool = true
    private var handBonesNodes: [String: SCNNode] = [:]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        print("[RingAR] 🎬 Init: Inicjalizuję RingARView")
        setupAR()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupAR() {
        print("[RingAR] ⚙️ Setup: Konfiguracja ARKit")
        arView = ARSCNView(frame: self.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.session = session
        arView.session.delegate = self
        
        // 🔑 Włączenie żółtych kropek debugowania
        arView.debugOptions = [.showFeaturePoints]
        
        // Bezpośrednia konfiguracja śledzenia dłoni dla iOS
        let config = ARHandTrackingConfiguration()
        config.maximumNumberOfTrackedHands = 1
        
        if #available(iOS 17.0, *) {
            config.handTrackingUsage = .heavy
        }
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        print("[RingAR] 📱 Setup: Uruchomiono ARHandTrackingConfiguration!")
        
        self.addSubview(arView)
    }
    
    // MARK: - Obsługa błędów
    func session(_ session: ARSession, didFailWithError error: Error) {
        print("[RingAR] ❌ BŁĄD SESJI AR: \(error.localizedDescription)")
    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState state: ARCamera.TrackingState) {
        print("[RingAR] 📷 Status kamery: \(state)")
    }
    
    // MARK: - Public API
    func setDebugGlove(enabled: Bool) {
        print("[RingAR] 🎮 setDebugGlove: enabled=\(enabled)")
        debugGloveEnabled = enabled
        DispatchQueue.main.async {
            self.handBonesNodes.values.forEach { $0.isHidden = !enabled }
        }
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let handAnchor = anchors.first(where: { $0 is ARHandAnchor }) as? ARHandAnchor else {
            DispatchQueue.main.async {
                self.handBonesNodes.values.forEach { $0.isHidden = true }
            }
            return
        }
        
        if Int.random(in: 1...30) == 1 {
            print("[RingAR] ✋ Wykryto dłoń!")
        }
        
        DispatchQueue.main.async {
            self.updateGlove(with: handAnchor)
        }
    }
    
    // MARK: - Budowanie Rękawiczki 3D
    private func updateGlove(with anchor: ARHandAnchor) {
        let skeleton = anchor.handSkeleton
        let jointIndices = skeleton.jointIndices
        
        let boneConnections: [(ARSkeleton.JointName, ARSkeleton.JointName)] = [
            (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
            (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
            (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
            (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
            (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip)
        ]
        
        for (jointAName, jointBName) in boneConnections {
            guard let transformA = skeleton.jointModelTransforms[jointIndices[jointAName.rawValue]],
                  let transformB = skeleton.jointModelTransforms[jointIndices[jointBName.rawValue]] else {
                continue
            }
            
            let posA = simd_float3(transformA.columns.3.x, transformA.columns.3.y, transformA.columns.3.z)
            let posB = simd_float3(transformB.columns.3.x, transformB.columns.3.y, transformB.columns.3.z)
            
            let boneKey = "\(jointAName.rawValue)-\(jointBName.rawValue)"
            
            if let existingNode = handBonesNodes[boneKey] {
                updateCapsule(node: existingNode, from: posA, to: posB)
                existingNode.isHidden = !debugGloveEnabled
            } else {
                let newNode = createCapsule(from: posA, to: posB)
                newNode.isHidden = !debugGloveEnabled
                arView.scene.rootNode.addChildNode(newNode)
                handBonesNodes[boneKey] = newNode
            }
        }
    }
    
    // MARK: - Helpery SceneKit
    private func createCapsule(from posA: simd_float3, to posB: simd_float3) -> SCNNode {
        let node = SCNNode()
        node.geometry = SCNCapsule(capRadius: 0.008, height: 0.01)
        
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.8)
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased
        node.geometry?.materials = [material]
        
        updateCapsule(node: node, from: posA, to: posB)
        return node
    }
    
    private func updateCapsule(node: SCNNode, from posA: simd_float3, to posB: simd_float3) {
        let vector = posB - posA
        let length = simd_length(vector)
        
        if let capsule = node.geometry as? SCNCapsule {
            capsule.height = CGFloat(max(0.001, length))
            let calculatedRadius = length * 0.15
            capsule.capRadius = CGFloat(max(0.005, min(0.025, calculatedRadius)))
        }
        
        let midpoint = (posA + posB) / 2
        node.simdPosition = midpoint
        
        let direction = simd_normalize(vector)
        let yAxis = simd_float3(0, 1, 0)
        
        if simd_dot(direction, yAxis) < 0.999 {
            let rotationAxis = simd_normalize(simd_cross(yAxis, direction))
            let dot = Swift.min(Swift.max(simd_dot(yAxis, direction), -1.0), 1.0)
            let angle = acos(dot)
            node.simdOrientation = simd_quatf(angle: angle, axis: rotationAxis)
        } else if simd_dot(direction, yAxis) < -0.999 {
            node.simdOrientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        }
    }
}