# Gives a recording that never got its summary (the bridge stopped in the
# middle) a proper end: reads what is there by scanning (up to the last
# whole record) and writes it again with Data End, the summary and the
# footer (Bag::Copy). The open chunk the bridge had not written yet is
# lost: at most Recorder::FLUSH_EVERY of messages. Returns the number of
# messages kept.
module Bag
  module Repair
    module_function

    def call(path)
      path = path.to_s
      tmp = "#{path}.repair"
      n = File.open(tmp, "wb") { |f| Copy.call(path, f) }
      File.rename(tmp, path)
      n
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
