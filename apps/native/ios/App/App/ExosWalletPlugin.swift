// ExosWallet: hand a .pkpass to Apple Wallet from the Exos app.
//
// A web view can't do it: Safari opens a .pkpass it navigates to in Wallet,
// WKWebView doesn't. The SPA's wallet adapter (apps/native/src/install.ts)
// fetches the signed pass from exos-wallet as before and passes the bytes
// here (base64); this shows the system "Add to Apple Wallet" sheet. It adds
// nothing on its own and sends nothing anywhere.
import Capacitor
import PassKit
import UIKit

@objc(ExosWalletPlugin)
public class ExosWalletPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ExosWalletPlugin"
    public let jsName = "ExosWallet"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "canAddPasses", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "addPass", returnType: CAPPluginReturnPromise),
    ]

    @objc func canAddPasses(_ call: CAPPluginCall) {
        call.resolve(["value": PKAddPassesViewController.canAddPasses()])
    }

    @objc func addPass(_ call: CAPPluginCall) {
        guard let b64 = call.getString("data"), let data = Data(base64Encoded: b64) else {
            call.reject("data must be the .pkpass bytes, base64")
            return
        }
        let pass: PKPass
        do {
            pass = try PKPass(data: data)
        } catch {
            call.reject("Not a valid Apple Wallet pass", nil, error)
            return
        }
        DispatchQueue.main.async {
            guard PKAddPassesViewController.canAddPasses(),
                  let sheet = PKAddPassesViewController(pass: pass),
                  let host = self.bridge?.viewController else {
                call.reject("Apple Wallet isn't available on this device")
                return
            }
            host.present(sheet, animated: true) {
                call.resolve(["shown": true])
            }
        }
    }
}
