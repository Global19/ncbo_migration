require_relative '../settings'

require 'logger'
require 'progressbar'

FileUtils.mkdir_p("./logs")
logger = Logger.new("logs/metrics_calculate.log")


puts "Loading submissions ..."
attributes = LinkedData::Models::OntologySubmission.attributes + [ontology: [:acronym]]
submissions = LinkedData::Models::OntologySubmission
                                         .where(submissionStatus: {code: "RDF"},
                                                summaryOnly: false)
                                         .include(attributes)
                                         .to_a
metrics_to_process = {}
submissions.each do |s|
  if metrics_to_process[s.ontology.acronym]
    if metrics_to_process[s.ontology.acronym].submissionId < s.submissionId
     metrics_to_process[s.ontology.acronym] = s
    end
  else
    metrics_to_process[s.ontology.acronym] = s
  end
end

subp = ProgressBar.new("Calculating metrics",metrics_to_process.length)
acronyms_sorted = metrics_to_process.keys.sort
acronyms_sorted.each do |acr|
  sub = metrics_to_process[acr]
  sub.bring_remaining
  if sub.metrics.nil?
    t0 = Time.now
    puts "calculating metrics for #{acr}"
    sub.process_metrics(logger)
    sub.save
    puts "calculated metrics for #{acr} in #{Time.now - t0} sec."
  end
  subp.inc
end

