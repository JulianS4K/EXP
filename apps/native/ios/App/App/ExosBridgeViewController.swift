// The app's web view controller (Main.storyboard): Capacitor's own, plus the
// app's local plugins, which have no npm package to register them.
import Capacitor
import UIKit

class ExosBridgeViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(ExosWalletPlugin())
    }
}
