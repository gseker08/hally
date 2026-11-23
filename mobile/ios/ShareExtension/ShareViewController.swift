import receive_sharing_intent

/// "Paylaş → Hally": hands the shared text, link or image to the app (through the App Group) and opens it.
/// The app turns it into a capture and shows the approval screen; nothing is saved before a parent approves.
class ShareViewController: RSIShareViewController {
  override func shouldAutoRedirect() -> Bool { true }
}
