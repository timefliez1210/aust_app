package com.aust.depthcapture;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * Android stub. There is no native ARCore implementation yet — checkSupport()
 * reports supported=false and the scan page runs its in-page guided camera
 * capture flow instead (getUserMedia in the WebView). Volume is estimated
 * server-side (VLM) for these submissions.
 */
@CapacitorPlugin(name = "DepthCapture")
public class DepthCapturePlugin extends Plugin {

    @PluginMethod
    public void checkSupport(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("supported", false);
        ret.put("hasLidar", false);
        call.resolve(ret);
    }

    @PluginMethod
    public void startSession(PluginCall call) {
        call.reject("Native AR capture is not available on Android");
    }

    @PluginMethod
    public void stopSession(PluginCall call) {
        call.resolve();
    }

    @PluginMethod
    public void getIntrinsics(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("fx", 0);
        ret.put("fy", 0);
        ret.put("cx", 0);
        ret.put("cy", 0);
        ret.put("width", 0);
        ret.put("height", 0);
        call.resolve(ret);
    }

    @PluginMethod
    public void getAllItems(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("items", new JSArray());
        call.resolve(ret);
    }

    @PluginMethod
    public void clearItems(PluginCall call) {
        call.resolve();
    }
}
