/*
* Copyright (c) 2026 Accelerate Networks LLC
*
* This file is part of linphone
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

import Foundation

/// The platform transport. The outbox is our durability; this is the platform's in-flight queue.
/// `nsurlsessiond` performs the upload out of process, so dispatch outlives the run.
final class Dispatcher: NSObject, URLSessionDataDelegate {
	static let sessionIdentifier = "com.acceleratenetworks.mobile.logforwarding"

	/// A body outlasting a url change is posted to the new destination.
	var destination: String
	var maxBackoff: TimeInterval

	private let outbox: Outbox
	private let state: DispatchState
	private var session: URLSession!

	/// Set by the app delegate when iOS relaunches us for background session events.
	var backgroundEventsCompletion: (() -> Void)?

	init(outbox: Outbox, destination: String, state: DispatchState, appGroup: String, maxBackoff: TimeInterval) {
		self.outbox = outbox
		self.destination = destination
		self.state = state
		self.maxBackoff = maxBackoff
		super.init()

		let configuration = URLSessionConfiguration.background(withIdentifier: Dispatcher.sessionIdentifier)
		configuration.sharedContainerIdentifier = appGroup
		// Explicit, so a platform default change cannot move the inactivity bound.
		configuration.timeoutIntervalForRequest = 60
		configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
		configuration.isDiscretionary = false
		configuration.httpMaximumConnectionsPerHost = 2
		session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}

	/// Apply outcomes the platform buffered while we were not running, before `inFlight` is
	/// consulted. The session's delegate queue is serial, so a reply to a query posted now lands
	/// behind every outcome already queued on it.
	func drain() {
		let semaphore = DispatchSemaphore(value: 0)
		session.getAllTasks { _ in semaphore.signal() }
		_ = semaphore.wait(timeout: .now() + 10)
	}

	/// Bodies the platform still holds.
	func inFlight() -> [FileId] {
		var identifiers: [FileId] = []
		let semaphore = DispatchSemaphore(value: 0)
		session.getAllTasks { tasks in
			identifiers = tasks.compactMap { $0.taskDescription.flatMap { FileId(rendered: $0) } }
			semaphore.signal()
		}
		_ = semaphore.wait(timeout: .now() + 10)
		return identifiers
	}

	/// Hand over every body in the frame not already in flight. There is no callback to the caller:
	/// a completion can arrive in a later process than the dispatch.
	func dispatch(_ directory: URL) {
		guard !destination.isEmpty, let url = URL(string: destination), !state.isBackedOff else { return }
		let held = Set(inFlight())
		for body in outbox.bodies(in: directory) {
			guard let id = InodeUtils.idOf(path: body.path), !held.contains(id) else { continue }
			var request = URLRequest(url: url)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
			let task = session.uploadTask(with: request, fromFile: body)
			task.taskDescription = id.description
			task.resume()
		}
	}

	// MARK: - Outcomes

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard let description = task.taskDescription, let id = FileId(rendered: description) else { return }
		let body = outbox.find(id: id)

		if let error = error {
			state.recordFailure(outcome: "\(error.localizedDescription)", retryAfter: nil, maxBackoff: maxBackoff)
			return
		}
		guard let response = task.response as? HTTPURLResponse else {
			state.recordFailure(outcome: "no response", retryAfter: nil, maxBackoff: maxBackoff)
			return
		}
		apply(status: response.statusCode, retryAfter: retryAfter(response), body: body)
	}

	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		let completion = backgroundEventsCompletion
		backgroundEventsCompletion = nil
		DispatchQueue.main.async { completion?() }
	}

	private func apply(status: Int, retryAfter: TimeInterval?, body: URL?) {
		switch status {
		case 200..<300:
			if let body = body { outbox.drop(body) }
			reportRecovery(outcome: String(status))
		case 413:
			Log.warn("[\(LogForwarding.forwarderTag)] endpoint refused a body as too large (413); max_post_bytes and the receiver's caps disagree")
			if let body = body, let halves = outbox.split(body) {
				// Off the session's delegate queue: dispatch queries the session and would deadlock on it.
				DispatchQueue.global(qos: .utility).async { self.dispatch(halves) }
			}
			reportRecovery(outcome: "413")
		case 429:
			state.recordFailure(outcome: "429", retryAfter: retryAfter, maxBackoff: maxBackoff)
		case 400..<500:
			Log.warn("[\(LogForwarding.forwarderTag)] dropping a body the endpoint refused with \(status): \(body?.lastPathComponent ?? "already gone")")
			if let body = body { outbox.drop(body) }
			reportRecovery(outcome: String(status))
		default:
			state.recordFailure(outcome: String(status), retryAfter: retryAfter, maxBackoff: maxBackoff)
		}
	}

	/// An outage is reported when it ends, and only one that reached the ceiling.
	private func reportRecovery(outcome: String) {
		guard let report = state.recordSuccess(outcome: outcome, maxBackoff: maxBackoff) else { return }
		let pending = outbox.pending().reduce(0) { $0 + outbox.bodies(in: $1).count }
		Log.warn("[\(LogForwarding.forwarderTag)] delivery recovered after \(Int(report.duration))s, \(report.failures) failed hand-overs, "
				 + "last outcome \(report.lastOutcome), \(pending) bodies still pending")
	}

	private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
		guard let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(value) else {
			return nil
		}
		return seconds
	}
}
