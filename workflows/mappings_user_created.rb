require_relative '../settings'

require 'logger'
require 'progressbar'
require_relative '../helpers/rest_helper'

FileUtils.mkdir_p("./logs")

MAPPINGS_EPR = "http://ncbostage-fsmaster1:8082/sparql/"
map_epr = SPARQL::Client.new(MAPPINGS_EPR)

MAPPING_IDS = <<eof
SELECT DISTINCT ?s WHERE {
GRAPH <http://purl.bioontology.org/mapping/rest> { 
?s a <http://protege.stanford.edu/ontologies/mappings/mappings.rdfs#One_To_One_Mapping> . }}
eof

MAPPING_DATA = <<eof
PREFIX map: <http://protege.stanford.edu/ontologies/mappings/mappings.rdfs#>
SELECT * {
GRAPH <http://purl.bioontology.org/mapping/rest> { 
 ?id map:has_process_info ?proc;
       map:relation ?rel;
       map:target ?target;
       map:source ?source;
       map:source_ontology ?source_ont;
       map:target_ontology ?target_ont .
 OPTIONAL { ?id map:comment ?comment . }
 FILTER (?id = <#ID>)
}}
eof

MAPPING_FIND = <<eof
PREFIX map: <http://protege.stanford.edu/ontologies/mappings/mappings.rdfs#>
SELECT * {
GRAPH <http://purl.bioontology.org/mapping/rest> { 
 ?id map:has_process_info ?proc;
       map:target <#TARGET>;
       map:source <#SOURCE>;
       map:source_ontology <#SOURCE_ONT>;
       map:target_ontology <#TARGET_ONT> .
}}
eof

PROC_QUERY = <<eof
PREFIX map: <http://protege.stanford.edu/ontologies/mappings/mappings.rdfs#>
SELECT * {
  ?id map:submitted_by ?creator .
  OPTIONAL { ?id map:mapping_source ?source . }
  OPTIONAL { ?id map:mapping_source_contact_info ?contact_info . }
  OPTIONAL { ?id map:mapping_source_name ?source_name . }
  OPTIONAL { ?id map:mapping_source_site ?site . }
  OPTIONAL { ?id map:date ?date }
 FILTER (?id = <#ID>)
}
eof

def proc_by_uri(id,batch)
  q= PROC_QUERY.dup
  q["#ID"] = id
  p= LinkedData::Models::MappingProcess.new
  p.id = RDF::URI.new(id)
  if p.exist?
    return LinkedData::Models::MappingProcess.find(p.id).first
  end
  map_epr = SPARQL::Client.new(MAPPINGS_EPR)
  map_epr.query(q).each do |sol|
    creator = RestHelper.user(sol[:creator].to_s)
    if creator
      creator = LinkedData::Models::User
          .find(RDF::URI.new("http://data.bioontology.org/users/#{creator[:username]}")).first
    end
    p.source = sol[:source]
    p.source_contact_info = sol[:contact_info]
    p.source_name = sol[:source_name]
    if creator
      p.creator = creator
    end
    p.date = sol[:date] ? sol[:date].object : nil
    p.valid?
    p.save(batch: batch)
    return p
  end
end

def ontology_acronym(ont_id)
  begin
    return RestHelper.latest_ontology(ont_id.split("/")[-1].to_i).abbreviation
  rescue OpenURI::HTTPError => e
    #puts "ontology not found #{ont_id}"
  end
  nil
end

def goo_ontology_from_acronym(acronym)
  return LinkedData::Models::Ontology.where(acronym: acronym).first
end

prog = ProgressBar.new("Ontologies ...", LinkedData::Models::Ontology.all.length)
ontologies = {}
LinkedData::Models::Ontology.all.each do |ont|
  break
  prog.inc
  begin
    sub = ont.latest_submission status: :RDF
    ontologies[ont.id.to_s] = sub if sub
  rescue => e
    puts "Error retrieving latest for #{ont.id.to_s}"
  end
end
prog.clear
#puts "#{ontologies.length} parsed submissions in the system."

transformed = Set.new
count_uni = 0
count_bi = 0 
mapping_ids = []
map_epr.query(MAPPING_IDS).each do |sol|
  mapping_id = sol[:s].to_s
  mapping_ids << mapping_id
end
prog = ProgressBar.new("Processing",mapping_ids.length)
batch_triples = File.open("./user_mappings.nt","w")
mapping_ids.each do |mapping_id|
  prog.inc
  mapping_query = MAPPING_DATA.dup
  next if transformed.include? mapping_id
  mapping_query["#ID"] = mapping_id
  found = nil
  map_epr.query(mapping_query).each do |sol_mapping|
    found = 1
    process_id = sol_mapping[:proc].to_s 
    find_query = MAPPING_FIND.dup
    find_query["#SOURCE"] = sol_mapping[:target].to_s
    find_query["#TARGET"] = sol_mapping[:source].to_s
    find_query["#SOURCE_ONT"] = sol_mapping[:target_ont].to_s
    find_query["#TARGET_ONT"] = sol_mapping[:source_ont].to_s
    inverse = nil
    map_epr.query(find_query).each do |sol_inverse|
      inverse = sol_inverse[:id].to_s
    end
    count_uni +=1 if inverse.nil?
    count_bi += 1 if inverse
    target_ontology = sol_mapping[:target_ont].to_s
    target_acr = ontology_acronym(target_ontology)
    target_ontology_object = goo_ontology_from_acronym(target_acr)
    target_term = sol_mapping[:target].to_s
    source_ontology = sol_mapping[:source_ont].to_s
    source_term = sol_mapping[:source].to_s
    source_acr = ontology_acronym(source_ontology)
    source_ontology_object = goo_ontology_from_acronym(source_acr)
    if source_acr && target_acr
      if source_ontology_object && target_ontology_object
        termm_s = LinkedData::Mappings.create_term_mapping([RDF::URI.new(target_term)],
                                                           target_acr,nil,batch_update_file=batch_triples)
        termm_t = LinkedData::Mappings.create_term_mapping([RDF::URI.new(source_term)],
                                                           source_acr,nil,batch_update_file=batch_triples)
        process = proc_by_uri(process_id,batch_triples)
        mapping_id = LinkedData::Mappings.create_mapping([termm_s, termm_t],batch_update_file=batch_triples)
        LinkedData::Mappings.connect_mapping_process(mapping_id, process,batch_update_file=batch_triples)
      else
        puts "could not create #{mapping_id}"
      end
    end

    transformed << mapping_id
    transformed << inverse if inverse
  end
  binding.pry unless found
end
batch_triples.close
mapping_graphs = [LinkedData::Models::TermMapping.type_uri,
                 LinkedData::Models::Mapping.type_uri,
                 LinkedData::Models::MappingProcess.type_uri]
if File.size("./user_mappings.nt") > 0
  Goo.sparql_data_client.append_triples_from_file(
                mapping_graphs, "./user_mappings.nt", "text/x-nquads")
end
