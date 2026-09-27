# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

require "../src/partiduo-migrate"
require "../config/settings/base"
require "../config/settings/**"
require "partiduo/cli"

require "marten/spec"

require "./support/**"
