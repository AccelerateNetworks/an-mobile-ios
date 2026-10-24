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

enum LogForwarding {
	/// Names the top-level system rather than the part within it, so every line the forwarding
	/// system writes opens with it whichever component wrote it. Kept in a file of its own because
	/// `msgNotificationService` compiles `TimezoneAnchor` and nothing else from this directory.
	static let forwarderTag = "forwarder"
}
