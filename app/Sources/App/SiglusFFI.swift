import Foundation

// MARK: - Rust engine C API (engine/siglus_rs)

// Import the engine's C header through SWIFT_OBJC_BRIDGING_HEADER. Direct
// references preserve these functions when Release linking strips unused code,
// and the compiler checks their C calling convention and argument types.
typealias SiglusMessageboxCallback = siglus_native_messagebox_callback_t

// Keep the existing optional adapter shape for the input fallback paths, but
// bind to the linked API. dlsym cannot discover symbols removed by dead stripping.
enum SiglusOptionalFFI {
    typealias WheelFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias MouseButtonFunction = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void

    typealias PrepareFunction = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias EditboxActiveFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias OpenMenuFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias SetSkipFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32

    static let wheel: WheelFunction? = siglus_ios_mouse_wheel
    static let mouseButton: MouseButtonFunction? = siglus_ios_mouse_button
    static let prepare: PrepareFunction? = siglus_ios_prepare
    static let editboxActive: EditboxActiveFunction? = siglus_ios_editbox_active
    static let openMenu: OpenMenuFunction? = siglus_ios_open_menu
    static let setSkip: SetSkipFunction? = siglus_ios_set_skip
    static let skipState: EditboxActiveFunction? = siglus_ios_is_skipping
}

/// Windows virtual-key codes understood by `vm_key_from_platform_code`.
enum SiglusVK {
    static let backspace: Int32 = 0x08
    static let tab: Int32 = 0x09
    static let enter: Int32 = 0x0D
    static let shift: Int32 = 0x10
    static let control: Int32 = 0x11
    static let alt: Int32 = 0x12
    static let escape: Int32 = 0x1B
    static let space: Int32 = 0x20
    static let end: Int32 = 0x23
    static let home: Int32 = 0x24
    static let left: Int32 = 0x25
    static let up: Int32 = 0x26
    static let right: Int32 = 0x27
    static let down: Int32 = 0x28
    static let delete: Int32 = 0x2E
}
