/// Display mode for detail surfaces: consultation shows committed values,
/// editing opens controls for them.
enum DetailDisplayMode: Equatable {
    /// Consultation: values render as read-only text until the user asks
    /// to change one.
    case consult
    /// Editing: inline controls are open and accept input.
    case edit
}
