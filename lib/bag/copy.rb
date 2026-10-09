# Copies the messages of an MCAP file into a new one (MCAP::Writer):
# every channel, or those the block keeps. For a recording without a
# summary (Bag::Repair) and for the "ROS 2 topics only" download, which
# `ros2 bag play` needs: it refuses a file whose channels do not all have
# the same serialization format ("Topics with different rmw serialization
# format have been found"), even when told to play only some topics.
# Returns the number of messages copied.
module Bag
  module Copy
    module_function

    def call(src_path, io, &keep)
      reader = MCAP::Reader.new(src_path.to_s)
      n = 0
      w = MCAP::Writer.new(io, profile: reader.header.profile, library: reader.header.library)
      ids = {}
      reader.each_message do |m, ch, schema|
        next if keep && !keep.call(ch)
        ids[ch.id] ||= begin
          sid = schema ? w.add_schema(name: schema.name, encoding: schema.encoding, data: schema.data) : 0
          w.add_channel(topic: ch.topic, message_encoding: ch.message_encoding, schema_id: sid, metadata: ch.metadata)
        end
        w.add_message(channel_id: ids[ch.id], log_time: m.log_time, publish_time: m.publish_time,
                      sequence: m.sequence, data: m.data)
        n += 1
      end
      w.finish
      n
    ensure
      reader&.close
    end

    # Only the ROS 2 topics (message encoding cdr).
    def ros2_only(src_path, io)
      call(src_path, io) { |ch| ch.message_encoding == "cdr" }
    end
  end
end
