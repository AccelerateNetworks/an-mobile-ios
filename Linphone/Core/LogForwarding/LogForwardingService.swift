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

import BackgroundTasks
import Foundation
import UIKit
import linphonesw

/// Owns the forwarder's schedule: the foreground loop, the `BGProcessingTask`, the background
/// session's relaunch events, and the timezone anchors. Only one run executes at a time, which the
/// serial queue is.
final class LogForwardingService {
	static let shared = LogForwardingService()
	/// Needs `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
	static let backgroundTaskIdentifier = "com.acceleratenetworks.mobile.logforwarding.process"

	private let queue = DispatchQueue(label: "com.acceleratenetworks.mobile.logforwarding", qos: .utility)
	private var forwarder: LogForwarder?
	private var settings: ForwarderConfig?
	private var source: Config?
	private var foregroundGeneration = 0
	private var registered = false

	private init() {}

	/// Must run before the app finishes launching: `BGTaskScheduler` refuses a later registration.
	func register() {
		guard !registered else { return }
		registered = true

		BGTaskScheduler.shared.register(forTaskWithIdentifier: LogForwardingService.backgroundTaskIdentifier, using: nil) { task in
			guard let task = task as? BGProcessingTask else { return }
			self.handle(task)
		}

		let center = NotificationCenter.default
		center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
			self.startForegroundLoop()
		}
		center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
			self.stopForegroundLoop()
			self.runOnLeavingForeground()
		}
		center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { _ in
			TimezoneAnchor.write()
		}
		center.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: nil) { _ in
			TimezoneAnchor.write()
		}
	}

	/// The forwarder reads `[log_forwarding]` from a `Config`, not from a Core.
	func start(config: Config) {
		queue.async {
			guard self.forwarder == nil else { return }
			self.source = config
			guard let group = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_NAME") as? String,
				  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
				Log.error("[\(LogForwarding.forwarderTag)] no app group container; log forwarding is off")
				return
			}

			let root = container.appendingPathComponent("LogForwarding", isDirectory: true)
			try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			DurableFile.excludeFromBackup(root)

			let loaded = ForwarderConfig.load(from: config)
			let state = ForwarderState(directory: root)
			let outbox = Outbox(root: root.appendingPathComponent("outbox", isDirectory: true))
			let dispatcher = Dispatcher(outbox: outbox,
										destination: loaded.url,
										state: DispatchState(directory: root),
										appGroup: group,
										maxBackoff: loaded.maxBackoff)
			let formatter = LogFormatter(identity: self.identity(config: config), settings: loaded.settings)
			let identity = ForwarderConfig.identity(from: config)
			formatter.tenant = identity.tenant
			formatter.extension = identity.extension
			let reader = LogReader(dir: Core.getLogCollectionPath,
								   prefix: Core.getLogCollectionPrefix,
								   extractor: Extractor(),
								   declaredTimezone: state.declaredTimezone ?? TimezoneAnchor.currentOffset(),
								   softLimit: loaded.softLimit,
								   documents: root,
								   state: state)

			self.settings = loaded
			self.forwarder = LogForwarder(reader: reader, formatter: formatter, outbox: outbox, dispatcher: dispatcher,
										  maxPostBytes: loaded.maxPostBytes, state: state, settings: loaded.settings)
			self.submitBackgroundRequest()
		}
		startForegroundLoop()
	}

	/// A settings change arrives through `ConfiguringState.Successful`: liblinphone re-reads the
	/// config in place, so the forwarder re-reads its own section and supersedes.
	func onConfigurationUpdated() {
		queue.async {
			guard let source = self.source, let forwarder = self.forwarder else { return }
			let loaded = ForwarderConfig.load(from: source)
			self.settings = loaded
			forwarder.dispatcher.destination = loaded.url
			forwarder.dispatcher.maxBackoff = loaded.maxBackoff
			forwarder.reader.softLimit = loaded.softLimit
			forwarder.maxPostBytes = loaded.maxPostBytes
			let identity = ForwarderConfig.identity(from: source)
			forwarder.formatter.tenant = identity.tenant
			forwarder.formatter.extension = identity.extension
			self.forwarder = forwarder.supersede(settings: loaded.settings)
		}
	}

	/// iOS relaunches the app for background session events, so outcomes from a previous process
	/// arrive before anything else runs.
	func handleBackgroundSessionEvents(completion: @escaping () -> Void) {
		queue.async {
			guard let forwarder = self.forwarder else {
				DispatchQueue.main.async { completion() }
				return
			}
			forwarder.dispatcher.backgroundEventsCompletion = completion
		}
	}

	// MARK: - The foreground loop

	/// Under no scheduler budget: runs with a wait of `foreground_interval` between them. That is a
	/// gap rather than a period.
	private func startForegroundLoop() {
		queue.async {
			self.foregroundGeneration += 1
			let generation = self.foregroundGeneration
			TimezoneAnchor.write()
			self.iterate(generation)
		}
	}

	private func stopForegroundLoop() {
		forwarder?.stop()
		queue.async { self.foregroundGeneration += 1 }
	}

	private func iterate(_ generation: Int) {
		guard generation == foregroundGeneration, let forwarder = forwarder else { return }
		forwarder.start()
		guard generation == foregroundGeneration else { return }
		let gap = settings?.foregroundInterval ?? 10
		queue.asyncAfter(deadline: .now() + gap) { self.iterate(generation) }
	}

	// MARK: - Background runs

	/// Leaving the foreground is the responsive path, not a supplement: during a reproduction this
	/// is what actually delivers.
	private func runOnLeavingForeground() {
		var identifier = UIBackgroundTaskIdentifier.invalid
		identifier = UIApplication.shared.beginBackgroundTask(withName: "log-forwarding") {
			self.forwarder?.stop()
		}
		guard identifier != .invalid else { return }
		queue.async {
			TimezoneAnchor.write()
			self.forwarder?.start()
			UIApplication.shared.endBackgroundTask(identifier)
		}
	}

	/// A `BGProcessingTaskRequest` is one-shot rather than periodic, so the next is submitted as
	/// this one begins: submitting at the end could leave a device torn down with nothing scheduled.
	private func handle(_ task: BGProcessingTask) {
		submitBackgroundRequest()
		task.expirationHandler = { self.forwarder?.stop() }
		queue.async {
			TimezoneAnchor.write()
			self.forwarder?.start()
			task.setTaskCompleted(success: true)
		}
	}

	/// `background_interval` is the request's `earliestBeginDate`, a floor rather than a schedule.
	private func submitBackgroundRequest() {
		let request = BGProcessingTaskRequest(identifier: LogForwardingService.backgroundTaskIdentifier)
		request.earliestBeginDate = Date(timeIntervalSinceNow: settings?.backgroundInterval ?? 86400)
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			Log.warn("[\(LogForwarding.forwarderTag)] could not schedule the background run: \(error.localizedDescription)")
		}
	}

	private func identity(config: Config) -> ResourceIdentity {
		return ResourceIdentity(
			serviceName: "an-mobile",
			deviceUuid: config.getString(section: "misc", key: "uuid", defaultString: ""),
			version: AppGitInfo.identifier,
			platform: "ios",
			process: String(cString: getprogname()),
			subsystem: Log.domain
		)
	}
}
