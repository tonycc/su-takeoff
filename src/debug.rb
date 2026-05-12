# src/debug.rb
# 调试输出模块：扫描和计算的每一步输出中间结果，方便人工复核。
# 通过 SuTakeoff::Debug.enabled = true/false 控制开关。
module SuTakeoff
  module Debug
    @enabled = false
    @indent = 0

    class << self
      attr_accessor :enabled

      def log(msg = "")
        return unless @enabled
        prefix = "  " * @indent
        puts "#{prefix}#{msg}"
      end

      def section(title)
        return unless @enabled
        log
        log "══════════════════════════════════════════════"
        log "  #{title}"
        log "══════════════════════════════════════════════"
      end

      def subsection(title)
        return unless @enabled
        log
        log "── #{title} ──"
      end

      def table(headers, rows)
        return unless @enabled
        return if rows.empty?
        widths = headers.map.with_index { |h, i|
          col = rows.map { |r| (r[i] || "").to_s.length }
          [h.length, *col].max
        }
        sep = widths.map { |w| "─" * (w + 2) }.join("┼")
        header_line = headers.map.with_index { |h, i| " #{h.ljust(widths[i])} " }.join("│")
        log "┌#{sep}┐"
        log "│#{header_line}│"
        log "├#{sep}┤"
        rows.each do |row|
          line = row.map.with_index { |cell, i| " #{cell.to_s.ljust(widths[i])} " }.join("│")
          log "│#{line}│"
        end
        log "└#{sep}┘"
      end

      def indent
        @indent += 1
        yield
      ensure
        @indent -= 1
      end

      def keyval(hash, indent_spaces: 4)
        return unless @enabled
        prefix = " " * (2 + @indent * 2 + indent_spaces)
        hash.each do |k, v|
          log "#{prefix}#{k}: #{v}"
        end
      end
    end
  end
end
