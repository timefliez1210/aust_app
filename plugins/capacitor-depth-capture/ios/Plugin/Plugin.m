#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

// Registers the Swift plugin class with the Capacitor Obj-C runtime.
CAP_PLUGIN(DepthCapturePlugin, "DepthCapture",
    CAP_PLUGIN_METHOD(checkSupport,   CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(startSession,   CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(stopSession,    CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(startItemScan,  CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(cancelItemScan, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setDrawMode,    CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getIntrinsics,  CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getAllItems,     CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(clearItems,     CAPPluginReturnPromise);
)
