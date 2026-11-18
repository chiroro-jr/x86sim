// makes res/sdkcovGK.sks on a Mac (swiftc sdkcovGK.swift && ./sdkcovGK: /tmp/sdkcovGK.sks): an SKScene archived as Xcode's scene
// editor does with a GameplayKit scene (keys root + _gkScene): one entity with a node component and a 2D agent
import SpriteKit
import GameplayKit
let scene = SKScene(size: CGSize(width: 320, height: 240)); scene.name = "sdkcovScene"
let s = SKNode(); s.name = "hero"; s.position = CGPoint(x: 40, y: 50); scene.addChild(s)
let l = SKNode(); l.name = "spawn"; l.position = CGPoint(x: 200, y: 100); scene.addChild(l)
let gk = GKScene(); gk.rootNode = scene
let e = GKEntity(); e.addComponent(GKSKNodeComponent(node: s)); e.addComponent(GKAgent2D()); gk.addEntity(e)
let a = NSKeyedArchiver(requiringSecureCoding: false)
a.encode(scene, forKey: "root"); a.encode(gk, forKey: "_gkScene"); a.finishEncoding()
try! a.encodedData.write(to: URL(fileURLWithPath: "/tmp/sdkcovGK.sks"))
let g = GKScene(fileNamed: "sdkcovGK")
print(g.map { "root \(String(describing: ($0.rootNode as? SKScene)?.name)) children \(($0.rootNode as? SKScene)?.children.map { $0.name ?? "?" } ?? []) entities \($0.entities.count) comps \($0.entities.first?.components.map { "\(type(of: $0))" } ?? []) node \(String(describing: $0.entities.first?.component(ofType: GKSKNodeComponent.self)?.node.name))" } ?? "nil")
