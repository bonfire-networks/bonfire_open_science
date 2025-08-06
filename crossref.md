# Crossref DOI Integration for Bonfire Posts

## Overview
This document outlines the development plan for integrating Crossref DOI registration into Bonfire, allowing posts to receive permanent Digital Object Identifiers (DOIs) for academic citation and archival purposes.

## Prerequisites

### Test Environment Setup
- [ ] Register for Crossref test account at https://test.crossref.org
- [ ] Obtain test credentials (username and password)
- [ ] Note your test DOI prefix (provided after registration)
- [ ] Test endpoint: `https://test.crossref.org/servlet/deposit`

## Implementation Checklist

### Phase 1: Core Infrastructure

#### 1. Configuration Module
- [ ] Add Crossref credentials to runtime config
- [ ] Create environment variables for:
  - `CROSSREF_USERNAME`
  - `CROSSREF_PASSWORD`
  - `CROSSREF_DOI_PREFIX`
  - `CROSSREF_TEST_MODE` (true/false)
  - `CROSSREF_DEPOSITOR_EMAIL`
  - `CROSSREF_DEPOSITOR_NAME`

#### 2. XML Builder Module (`lib/apis/crossref_deposit.ex`)
- [ ] Create XML generator for posted-content type
- [ ] Implement required fields mapping:
  - [ ] Title from `PostContent.name`
  - [ ] Posted date from `inserted_at`
  - [ ] DOI data (generated DOI and resource URL)
- [ ] Implement optional fields mapping:
  - [ ] Abstract from `PostContent.summary`
  - [ ] Authors from `Profile.name` and `Character.username`
  - [ ] Content type (default to "preprint")
  - [ ] Group title/categories from post tags

#### 3. DOI Management Module (`lib/doi_manager.ex`)
- [ ] `generate_doi/1` - Create DOI from post ULID
  ```elixir
  def generate_doi(post_id) do
    prefix = Config.get(:crossref_doi_prefix)
    "#{prefix}/bonfire.#{post_id}"
  end
  ```
- [ ] `register_doi_for_post/2` - Main registration function
- [ ] `build_crossref_metadata/1` - Extract post data for XML
- [ ] `submit_to_crossref/2` - HTTP POST to Crossref
- [ ] `store_doi_metadata/2` - Save DOI in Media.metadata

#### 4. HTTP Client Integration
- [ ] Use existing Fetcher module or Tesla client
- [ ] Implement multipart/form-data POST
- [ ] Handle response and error cases
- [ ] Parse submission ID for tracking

### Phase 2: Data Storage

#### 5. Database Updates
- [ ] Store DOI in `Media.metadata` JSON field:
  ```elixir
  %{
    "doi" => "10.TEST/bonfire.01234567",
    "doi_status" => "pending|registered|failed",
    "doi_submitted_at" => datetime,
    "crossref_submission_id" => "12345"
  }
  ```
- [ ] Consider adding index on metadata->>'doi' for lookups

### Phase 3: User Interface

#### 6. UI Components
- [ ] Create `RegisterDoiLive` component
  - [ ] "Register DOI" button for post authors
  - [ ] Show DOI modal for adding/editing relevant information
  - [ ] Show registration status
  - [ ] Display registered DOI with copy button
- [ ] Add DOI display to existing post views
- [ ] Integrate with `AcademicPaperLive` component

#### 7. Permissions & Settings
- [ ] Check user has permission to register DOI
- [ ] Add setting to enable/disable DOI registration

### Phase 4: Testing & Validation

#### 8. Testing
- [ ] Unit tests for XML generation
- [ ] Integration test with Crossref test API
- [ ] Verify DOI resolution in test environment
- [ ] Test error handling and retries

## Technical Architecture

### Module Structure
```
extensions/bonfire_open_science/
├── lib/
│   ├── apis/
│   │   ├── crossref_deposit.ex    # XML generation & submission
│   │   └── doi.ex                  # Existing DOI utilities
│   ├── doi_manager.ex              # Business logic for DOI registration
│   └── web/
│       └── components/
│           └── register_doi_live.ex # UI component
```

### Data Flow
1. User triggers DOI registration from UI
2. `DoiManager.register_doi_for_post/2` called
3. Post data extracted and mapped to Crossref schema
4. XML generated via `CrossrefDeposit.build_xml/1`
5. HTTP POST to Crossref test endpoint
6. Response parsed, DOI stored in `Media.metadata`
7. UI updated with DOI or error status

## API Integration Details

### Crossref XML Schema (Minimal)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<doi_batch version="5.3.1" xmlns="http://www.crossref.org/schema/5.3.1">
  <head>
    <doi_batch_id>batch_#{timestamp}</doi_batch_id>
    <timestamp>#{unix_timestamp}</timestamp>
    <depositor>
      <depositor_name>#{depositor_name}</depositor_name>
      <email_address>#{depositor_email}</email_address>
    </depositor>
    <registrant>Bonfire</registrant>
  </head>
  <body>
    <posted_content type="preprint">
      <contributors>
        <person_name sequence="first" contributor_role="author">
          <given_name>#{author_first}</given_name>
          <surname>#{author_last}</surname>
        </person_name>
      </contributors>
      <titles>
        <title>#{post_title}</title>
      </titles>
      <posted_date>
        <month>#{month}</month>
        <day>#{day}</day>
        <year>#{year}</year>
      </posted_date>
      <doi_data>
        <doi>#{generated_doi}</doi>
        <resource>#{post_permalink}</resource>
      </doi_data>
    </posted_content>
  </body>
</doi_batch>
```

### HTTP Request Format
```bash
curl -F 'operation=doMDUpload' \
     -F 'login_id=USERNAME' \
     -F 'login_passwd=PASSWORD' \
     -F 'fname=@crossref_deposit.xml' \
     https://test.crossref.org/servlet/deposit
```

## Testing Strategy

### Manual Testing Steps
1. Create a test post with title and content
2. Click "Register DOI" button
3. Verify XML generation in logs
4. Check Crossref test dashboard for submission
5. Verify DOI stored in database
6. Test DOI resolution at test.crossref.org

### Automated Testing
```elixir
describe "DOI Registration" do
  test "generates valid Crossref XML" do
    post = Fake.post!()
    xml = CrossrefDeposit.build_xml(post)
    assert xml =~ ~r/<doi_batch/
    assert xml =~ post.post_content.name
  end
  
  test "registers DOI with test endpoint" do
    post = Fake.post!()
    {:ok, doi} = DoiManager.register_doi_for_post(post, current_user)
    assert doi =~ ~r/10\.TEST/
  end
end
```

## Environment Variables

Add to `.env`:
```bash
# Crossref Test Credentials
CROSSREF_USERNAME=your_test_username
CROSSREF_PASSWORD=your_test_password
CROSSREF_DOI_PREFIX=10.TEST
CROSSREF_TEST_MODE=true
CROSSREF_DEPOSITOR_NAME="Your Name"
CROSSREF_DEPOSITOR_EMAIL=your.email@example.com
```

## Future Enhancements

### Phase 2 Features
- [ ] Bulk DOI registration for multiple posts
- [ ] DOI versioning for updated posts
- [ ] Citation tracking and metrics
- [ ] Reference/bibliography extraction from posts
- [ ] Auto-registration based on post type/tags
- [ ] Integration with ORCID for author identification
- [ ] Support for other content types (datasets, software)
- [ ] Crossref Event Data integration
- [ ] DOI resolution landing page customization

### Production Considerations
- [ ] Switch to production endpoint
- [ ] Implement retry logic for failed submissions
- [ ] Add monitoring and alerting
- [ ] Consider caching DOI metadata
- [ ] Rate limiting for API calls
- [ ] Backup and recovery for DOI records

## Resources

- [Crossref Test System](https://test.crossref.org)
- [Crossref XML Schema Documentation](https://www.crossref.org/documentation/schema-library/)
- [Posted Content Markup Guide](https://www.crossref.org/documentation/schema-library/markup-guide-record-types/posted-content-includes-preprints/)
- [HTTPS POST Documentation](https://www.crossref.org/documentation/register-maintain-records/direct-deposit-xml/https-post/)
- [Crossref Support](https://support.crossref.org)

## Notes

- Test DOIs will only resolve in the test environment
- Production requires Crossref membership and fees
- Consider DataCite as an alternative for open science projects
- DOI format: `10.PREFIX/bonfire.ULID` ensures uniqueness