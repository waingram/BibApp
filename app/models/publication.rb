class Publication < ActiveRecord::Base
     
  #### Validations ####

  #### Associations ####
  
  belongs_to :publisher
  belongs_to :authority,
    :class_name => "Publication",
    :foreign_key => :authority_id
  has_many :works, :conditions => ["work_state_id = ?", 3] #accepted works
  
  has_many :identifyings, :as => :identifiable
  has_many :identifiers, :through => :identifyings
  
  named_scope :authorities, :conditions => ["id = authority_id"]

  # This is necessary due to very long titles for conference
  # proceedings. For example:
  # Cultivating the future based on science. Volume 1: Organic Crop
  # Production. Proceedings of the Second Scientific Conference of the
  # International Society of Organic Agriculture Research (ISOFAR), held at
  # the 16th IFOAM Organic World Conference in Cooperation with the
  # International Federation of Organic Agriculture Movements (IFOAM) and
  # the Consorzio ModenaBio in Modena, Italy, 18-20 June, 2008
  validates_length_of :name, :maximum => 255,
    :too_long => "is too long (maximum is 255 characters): {{value}}"
  
  #### Callbacks ####
  
  #Called after create only
  def after_create
    #Authority defaults to self
    self.authority_id = self.id
    self.save
  end
  
  #Note: 'after_save' callback is located in 'publication_observer.rb', to make
  # sure it is called *before* after_save in 'index_observer.rb'
  # (That way Publication info is updated completely *before* re-indexing of works)
  
  #### Methods ####
  
  def validate_name
    "#{self.name} #{self.issn_isbn}".downcase.gsub(/[^a-zA-Z0-9]+/, "")
  end

  def publisher_name
    publisher.name if publisher
  end
  
  def publisher_name=(name)
    if name.blank?
      name = "Unknown"
    end
    self.publisher = Publisher.find_or_create_by_name(name) unless name.blank?
  end
  
  def isbns
    isbns = Array.new
    ids = self.identifiers.find(:all, :conditions => [ 'type=?', 'ISBN']).collect{|isbn| {:name => isbn.name, :id => isbn.id}}
    ids.each do |id|
      isbns << {:name => id[:name], :id => id[:id]}
    end
    return isbns
  end
  
  def issns
    issns = self.identifiers.find(:all, :conditions => [ 'type=?', 'ISSN']).collect{|issn| {:name => issn.name, :id => issn.id}}
  end
  
  def parse_identifiers
    if self.issn_isbn.blank?
      return
    else
      # Loop thru all publication issn_isbn values
      self.issn_isbn.each do |issn_isbn| 

        # Field might be separated
        issn_isbn.split("; ").each do |identifier|

          # No spaces, no hyphens, no quotes -- @TODO: Do this better!
          identifier = identifier.strip.gsub(" ", "").gsub("-", "").gsub('"', "")

          # Init new Identifier
          id = Identifier.new
          parsed_id = id.parse(identifier)
          if !parsed_id[0].blank?
            pub_id = Identifier.find_or_initialize_by_name(:name => parsed_id[1])
            pub_id[:type] = parsed_id[0] if !parsed_id[0].blank?
            pub_id.save
            if self.identifiers.include?(pub_id)
              # Do nothing
            else
              self.identifiers << pub_id
            end
            self.save_without_callbacks
          else
            # Do Nothing
          end
        end
      end
    end
  end
  
  def save_without_callbacks
    update_without_callbacks
  end
  
  def to_param
    param_name = name.gsub(" ", "_")
    param_name = param_name.gsub(/[^A-Za-z0-9_]/, "")
    "#{id}-#{param_name}"
  end
  
  # Convert object into semi-structured data to be stored in Solr
  def to_solr_data
    "#{name}||#{id}" unless self.nil?
  end
  
  def solr_filter
    'publication_id:"' + self.id.to_s + '"'
  end

  def form_select
    "#{name.first(100)+"..."} - #{issn_isbn}"
  end

  def authority_for
    authority_for = Publication.find(
      :all, 
      :conditions => ["authority_id = ?", self.id]
    )
    return authority_for
  end
  
  def authority_for_work_count
    Work.find(:all, :conditions => ["authority_publication_id = ? and work_state_id = ?", self.id, 3]).size
  end
  
  #Update authorities for related models, when Publication Authority changes
  # (called by after_save callback)
  def update_authorities
    # If Publication authority changed, we need to echo new authority key
    # to each related model.
    logger.debug("\n\nPub: #{self.id} | Auth: #{self.authority_id}\n\n")
    if self.authority_id_changed? and self.authority_id != self.id or self.publisher_id_changed?
      
      # Update publications
      logger.debug("\n\n===Updating Publications===\n\n")
      self.authority_for.each do |pub|
        pub.authority_id = self.authority_id
        pub.save
      end
      
      # Update works
      logger.debug("\n\n===Updating Works===\n\n")
      self.works.each do |work|
        work.publication_id = self.authority_id
        work.publisher_id = self.authority.publisher.authority_id
        work.save_and_set_for_index_without_callbacks
      end
      
      # Reindex
      logger.debug("\n\n===Reindexing Works===\n\n")
      Index.batch_index
    end
  end
  
  #Update Machine Name of Publication (called by after_save callback)
  def update_machine_name
    #Machine name only needs updating if there was a name change
    if self.name_changed?
      #Machine name is Name with:
      #  1. all punctuation/spaces converted to single space
      #  2. stripped of leading/trailing spaces and downcased
      self.machine_name = self.name.mb_chars.gsub(/[\W]+/, " ").strip.downcase
      self.save_without_callbacks
    end
  end
  
  class << self

    # return the first letter of each name, ordered alphabetically
    def letters
      find(
        :all,
        :select => 'DISTINCT SUBSTR(name, 1, 1) AS letter',
        :order  => 'letter'
      )
    end
  
    def update_multiple(pub_ids, auth_id)
      pub_ids.each do |pub|
        update = Publication.find_by_id(pub)
        update.authority_id = auth_id
        update.save
      end
    end
    
    #Parse Solr data (produced by to_solr_data)
    # return Publication name and ID
    def parse_solr_data(publication_data)
      if publication_data.blank?
        return nil, nil
      else
        data = publication_data.split("||")
        name = data[0]
        id = data[1]

        return name, id
      end
    end
  end
end
