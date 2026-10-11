import SwiftUI

struct IncomingCallView: View {
    @Bindable var contact: MobileContact
    var body: some View {
        CallScreen(voice: contact.voice, name: contact.detail?.name ?? "Hermes", reason: contact.detail?.reason,
                   ringing: !contact.callIsAccepted, preparing: contact.callIsAccepted && !contact.voice.active && contact.voice.error == nil,
                   onAnswer: { contact.answer() },
                   onLater: contact.detail?.canPostpone == true ? {
                       contact.postponeTarget = contact.callInvitation
                       contact.callPresentation.isPresented = false
                       contact.chooseCallTime = true
                   } : nil,
                   onEnd: { contact.end() },
                   onClose: {
                       if contact.callIsAccepted { contact.callPresentation.isPresented = false }
                       else { contact.end() }
                   })
    }
}
