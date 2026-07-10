package me.pinlin.broadlink_setup

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Channel and WifiBinder lifecycle live in WifiBinderPlugin so
        // onDetachedFromEngine (fires on hot-restart and engine teardown)
        // gets a chance to call binder.leave() — without this the phone
        // stays stranded on the device AP after a debug hot-restart.
        flutterEngine.plugins.add(WifiBinderPlugin())
    }
}
