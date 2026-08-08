# Membrane narrates every link, state change and buffer at :debug, which buries
# actual test output.
Logger.configure(level: :warning)

ExUnit.start()
