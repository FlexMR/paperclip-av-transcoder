module Paperclip
  class Transcoder < Processor
    attr_accessor :geometry, :format, :whiny, :convert_options
    # Creates a Video object set to work on the +file+ given. It
    # will attempt to transcode the video into one defined by +target_geometry+
    # which is a "WxH"-style string. +format+ should be specified.
    # Video transcoding will raise no errors unless
    # +whiny+ is true (which it is, by default. If +convert_options+ is
    # set, the options will be appended to the convert command upon video transcoding.
    def initialize file, options = {}, attachment = nil
      @file             = file
      @current_format   = File.extname(@file.path)
      @basename         = File.basename(@file.path, @current_format)
      @cli              = ::Av.cli
      @meta             = ::Av.cli.identify(@file.path)
      @whiny            = options[:whiny].nil? ? true : options[:whiny]

      @convert_options  = set_convert_options(options)

      @format           = options[:format]

      @geometry         = options[:geometry]
      unless @geometry.nil?
        modifier = @geometry[0]
        @geometry[0] = '' if ['#', '<', '>'].include? modifier
        @width, @height   = @geometry.split('x')
        @keep_aspect      = @width[0] == '!' || @height[0] == '!'
        @pad_only         = @keep_aspect    && modifier == '#'
        @enlarge_only     = @keep_aspect    && modifier == '<'
        @shrink_only      = @keep_aspect    && modifier == '>'
      end

      @time             = options[:time].nil? ? 3 : options[:time]
      @auto_rotate      = options[:auto_rotate].nil? ? false : options[:auto_rotate]
      @pad_color        = options[:pad_color].nil? ? "black" : options[:pad_color]

      @convert_options[:output][:s] = format_geometry(@geometry) if @geometry.present?

      attachment.instance_write(:meta, @meta) if attachment
    end

    # Performs the transcoding of the +file+ into a thumbnail/video. Returns the Tempfile
    # that contains the new image/video.
    def make
      ::Av.logger = Paperclip.logger
      @cli.add_source @file
      dst = Tempfile.new([@basename, @format ? ".#{@format}" : ''])
      dst.binmode

      if @meta
        log "Transocding supported file #{@file.path}"
        @cli.add_source(@file.path)
        @cli.add_destination(dst.path)
        @cli.reset_input_filters

				if @auto_rotate && @meta[:rotate]
	        # actual rotation no longer needed since ffmpeg will handle this automatically
					@cli.metadata_rotate 0
	      end

        if output_is_image?
          @time = @time.call(@meta, @options) if @time.respond_to?(:call)
          @cli.filter_seek @time
        end

        if @convert_options.present?
          if @convert_options[:input]
            @convert_options[:input].each do |h|
              @cli.add_input_param h
            end
          end
          if @convert_options[:output]
            @convert_options[:output].each do |h|
              @cli.add_output_param h
            end
          end
        end

        begin
          @cli.run
          log "Successfully transcoded #{@basename} to #{dst}"
        rescue Cocaine::ExitStatusError => e
          raise Paperclip::Error, "error while transcoding #{@basename}: #{e}" if @whiny
        end
      else
        log "Unsupported file #{@file.path}"
        # If the file is not supported, just return it
        dst << @file.read
        dst.close
      end
      dst
    end

    def log message
      Paperclip.log "[transcoder] #{message}"
    end

    def set_convert_options options
      return options[:convert_options] if options[:convert_options].present?
      options[:convert_options] = {output: {}}
      return options[:convert_options]
    end

    def format_geometry geometry
      return unless geometry.present?
      return geometry.gsub(/[#!<>)]/, '')
    end

    def output_is_image?
      !!@format.to_s.match(/jpe?g|png|gif$/)
    end

		def format_geometry geometry
			geometry.present? ? calculate_geometry : nil
	  end

		def calculate_geometry
			keep_aspect     = !@geometry.nil? && @geometry[-1,1] != '!'
	    pad_only        = keep_aspect    && @geometry[-1,1] == '#'
	    enlarge_only    = keep_aspect    && @geometry[-1,1] == '<'
	    shrink_only     = keep_aspect    && @geometry[-1,1] == '>'

	    # Extract target dimensions
	    if @geometry =~ /(\d*)x(\d*)/
	      target_width = $1
	      target_height = $2
	    end

			return nil unless @meta[:size].present?

	    current_width, current_height = @meta[:size].split('x')

	    if @auto_rotate && @meta[:rotate] && @meta[:rotate] && [90,180].include?(@meta[:rotate]) # calculate as if already rotated
	      current_width, current_height = current_height, current_width
	      @meta[:aspect] = (1.to_f / @meta[:aspect])
	    end

	    # Current width and height
	    if keep_aspect
	      if target_width.blank? # fixed height
	        calculate_fixed_height(target_height, @meta[:aspect])
	      elsif target_height.blank? # fixed width
					calculate_fixed_width(target_width, @meta[:aspect])
	      elsif enlarge_only
	        calculate_enlarge_only(current_width, current_height, target_width, target_height, @meta[:aspect])
	      elsif shrink_only
					calculate_shrink_only(current_width, current_height, target_width, target_height, @meta[:aspect])
	      elsif pad_only
	        calculate_pad_only(target_width, target_height, @meta[:aspect])
	      else
	        # Keep aspect ratio
	        calculate_scale_only(current_width, current_height, target_width, target_height, @meta[:aspect])
	      end
	    else
	      # Do not keep aspect ratio
	      "#{target_width.to_i/2*2}x#{target_height.to_i/2*2}"
	    end
		end

		def calculate_fixed_height(target_height, aspect)
			height = target_height.to_i
	    width = (height.to_f * aspect.to_f).to_i
	    "#{width.to_i/2*2}x#{height}"
		end

		def calculate_fixed_width(target_width, aspect)
			width = target_width.to_i
	    height = (width.to_f / aspect.to_f).to_i
	    "#{width}x#{height.to_i/2*2}"
		end

		def calculate_enlarge_only(current_width, current_height, target_width, target_height, aspect)
			if current_width.to_i < target_width.to_i
	      # Keep aspect ratio
	      width = target_width.to_i
	      height = (width.to_f / aspect.to_f).to_i
	      "#{width.to_i/2*2}x#{height.to_i/2*2}"
	    else
	      #Source is Larger than Destination, Doing Nothing
	      #return nil
	    end
		end

		def calculate_shrink_only(current_width, current_height, target_width, target_height, aspect)
			if current_width.to_i > target_width.to_i
	      # Keep aspect ratio

	      if (target_width.to_f / current_width.to_i) > (target_height.to_f / current_height.to_i)
	        height = target_height.to_i
	        width = (height.to_f * @meta[:aspect].to_f).to_i
	      else
	        width = target_width.to_i
	        height = (width.to_f / (@meta[:aspect].to_f)).to_i
	      end
	      "#{width.to_i/2*2}x#{height.to_i/2*2}"
	    elsif current_height.to_i > target_height.to_i
	      height = target_height.to_i
	      width = (height.to_f * @meta[:aspect].to_f).to_i
	      "#{width.to_i/2*2}x#{height.to_i/2*2}"
	    else
	      #return nil
	    end
		end

		def calculate_pad_only(target_width, target_height, aspect)
			# Keep aspect ratio
	    width = target_width.to_i
	    height = (width.to_f / aspect.to_f).to_i
	    # We should add half the delta as a padding offset Y
	    pad_y = (target_height.to_f - height.to_f) / 2
	    # There could be options already set
	    @convert_options[:output][:vf][/\A/] = ',' if @convert_options[:output][:vf]
	    @convert_options[:output][:vf] ||= ''
	    if pad_y > 0
	      @convert_options[:output][:vf][/\A/] = "scale=#{width}:-1,pad=#{width.to_i}:#{target_height.to_i}:0:#{pad_y}:#{@pad_color}"
	    else
	      @convert_options[:output][:vf][/\A/] = "scale=#{width}:-1,crop=#{width.to_i}:#{height.to_i}"
	    end
		end

		def calculate_scale_only(current_width, current_height, target_width, target_height, aspect)
			if (target_height.to_f / current_height.to_f) < (target_width.to_f / current_width.to_f)
	      height = target_height.to_i
	      width = (height.to_f * aspect.to_f).to_i
	    else
	      width = target_width.to_i
	      height = (width.to_f / aspect.to_f).to_i
	    end
	    "#{width.to_i/2*2}x#{height.to_i/2*2}"
		end
  end

  class Attachment
    def meta
      instance_read(:meta)
    end
  end
end
