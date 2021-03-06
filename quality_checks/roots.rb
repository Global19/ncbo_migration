require_relative '../settings.rb'
require_relative '../helpers/rest_helper'

puts ["ontology".ljust(15), "production".rjust(10), "new api".rjust(10)].join("\t\t")

rest_ontologies = RestHelper.ontologies
rest_ontologies.sort! {|a,b| a.abbreviation.downcase <=> b.abbreviation.downcase}
rest_ontologies.each do |rest_ont|
  begin
    rest_roots = RestHelper.roots(rest_ont.id).length
  rescue Timeout::Error
    puts "#{rest_ont.abbreviation} timed out on REST"
    next
  rescue
    puts "#{rest_ont.abbreviation} failed on REST"
    next
  end
  
  ont = LinkedData::Models::Ontology.find(rest_ont.abbreviation).first
  next unless ont
  sub = ont.latest_submission rescue next
  next unless sub
  roots = sub.roots.length
  
  difference = rest_roots.to_f / roots.to_f
  bad = "*" if difference < 0.9 || difference > 1.1
  puts ["#{rest_ont.abbreviation} #{bad}".ljust(15), rest_roots.to_s.rjust(10), roots.to_s.rjust(10)].join("\t\t")
end

