Pod::Spec.new do |s|
  s.name             = 'CapacitorDepthCapture'
  s.version          = '0.0.1'
  s.summary          = 'AR per-item arc-sweep capture plugin for Capacitor'
  s.homepage         = 'https://github.com/timefliez1210/aust_backend'
  s.license          = { :type => 'MIT' }
  s.author           = 'Aust Umzüge'
  s.source           = { :git => 'https://github.com/timefliez1210/aust_backend.git', :tag => s.version.to_s }
  s.ios.deployment_target = '16.0'

  s.source_files  = 'ios/Plugin/**/*.{swift,m,h}'
  # Bundle furniture_labels.json and any YOLO model the developer drops in
  s.resources     = ['ios/Plugin/*.json', 'ios/Plugin/*.mlmodelc', 'ios/Plugin/*.mlpackage']

  s.dependency 'Capacitor'
  s.swift_version = '5.9'

  # ARKit, Vision (YOLO inference), SceneKit (ARSCNView), CoreML (YOLO model loading)
  s.frameworks = 'ARKit', 'Vision', 'CoreML', 'SceneKit'
end
