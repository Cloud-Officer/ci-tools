# frozen_string_literal: true

# Shows AMI builds: redrawn in place on a terminal, one line per change otherwise.
class AmiStatusTable
  ROW_FORMAT = '%-10<instance>s %-10<state>s %6<progress>s  %-22<ami>s %6<elapsed>s  %<detail>s'
  HEADER = format(ROW_FORMAT, instance: 'INSTANCE', state: 'STATE', progress: 'SNAP', ami: 'AMI', elapsed: 'TIME', detail: 'NAME')
  private_constant :ROW_FORMAT, :HEADER

  def initialize(jobs, out)
    @jobs = jobs
    @out = out
    @drawn = false
    @last = {}
  end

  def render
    @out.tty? ? redraw : print_changes
  end

  private

  def row(job)
    fields = job.snapshot
    format(ROW_FORMAT, instance: job.instance, state: fields[:state], progress: fields[:progress] || '?', ami: fields[:ami_id] || '-', elapsed: job.elapsed, detail: fields[:error] || fields[:name])
  end

  def redraw
    lines = [HEADER] + @jobs.map { |job| row(job) }
    @out.print("\e[#{lines.size}A") if @drawn
    lines.each { |line| @out.print("\e[2K#{line}\n") }
    @drawn = true
  end

  def print_changes
    @jobs.each do |job|
      key = job.snapshot.slice(:state, :progress, :ami_id, :error)
      next if @last[job.instance] == key

      @last[job.instance] = key
      @out.puts(row(job))
    end
  end
end
