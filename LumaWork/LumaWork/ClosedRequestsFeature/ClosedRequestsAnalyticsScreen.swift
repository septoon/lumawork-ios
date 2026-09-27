import SwiftUI

struct ClosedRequestsAnalyticsScreen: View {
    let snapshot: ClosedRequestsSnapshot?
    let records: [ClosedRequestRecord]
    var showsCloseButton = true

    var body: some View {
        ClosedRequestsAnalyticsContent(
            snapshot: snapshot,
            records: records,
            showsCloseButton: showsCloseButton
        )
    }
}
