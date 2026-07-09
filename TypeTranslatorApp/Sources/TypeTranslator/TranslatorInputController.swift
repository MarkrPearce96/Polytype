import InputMethodKit

/// The input controller macOS instantiates for each text field we're active in.
/// The `@objc(TranslatorInputController)` name is what the bundle's Info.plist
/// `InputMethodServerControllerClass` refers to. Keystroke/composing logic is
/// added in Task 7.
@objc(TranslatorInputController)
class TranslatorInputController: IMKInputController {
}
