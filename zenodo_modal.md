# Zenodo DOI Modal Integration Plan

## Overview
This document outlines the implementation plan for a modal interface to collect and edit metadata when creating DOIs with Zenodo. The modal will provide a user-friendly form for entering required and optional metadata fields before submitting to Zenodo's API.

## Minimum Viable Metadata Fields

### Required Fields (Phase 1)

#### 1. Upload Type
- **Field**: `upload_type`
- **UI**: Dropdown/Select
- **Options**: 
  - `publication` (default for posts)
  - `dataset`
  - `software`
  - `other`
- **Auto-populate**: Default to "publication" for text posts

#### 2. Title
- **Field**: `title`
- **UI**: Text input
- **Auto-populate**: From `PostContent.name` or first line of content
- **Validation**: Required, max 500 chars

#### 3. Creators/Authors
- **Field**: `creators`
- **UI**: Dynamic list with "Add Author" button
- **Fields per creator**:
  - Name (required): "Family name, Given names"
  - ORCID (optional): Text input with format validation
  - Affiliation (optional): Text input
- **Auto-populate**: Current user's profile name
- **Validation**: At least one creator required

#### 4. Description
- **Field**: `description`
- **UI**: Textarea
- **Auto-populate**: From `PostContent.summary` or `PostContent.html_body` (truncated)
- **Note**: Supports limited HTML tags
- **Validation**: Required, min 10 chars

#### 5. Publication Date
- **Field**: `publication_date`
- **UI**: Date picker
- **Auto-populate**: Post's `inserted_at` timestamp
- **Format**: YYYY-MM-DD

#### 6. Access Rights
- **Field**: `access_right`
- **UI**: Radio buttons
- **Options**:
  - `open` (default)
  - `embargoed`
  - `restricted`
  - `closed`
- **Auto-populate**: Default to "open"

#### 7. License (conditional)
- **Field**: `license`
- **UI**: Dropdown
- **Show when**: `access_right` is "open" or "embargoed"
- **Common options**:
  - `CC-BY-4.0` (default)
  - `CC-BY-SA-4.0`
  - `CC0-1.0`
  - `MIT`
  - `Apache-2.0`
- **Link**: "Choose a license" helper link

### Optional Fields (Phase 1)

#### 8. Keywords
- **Field**: `keywords`
- **UI**: Tag input (comma-separated)
- **Auto-populate**: From post tags if available
- **Placeholder**: "keyword1, keyword2, keyword3"

### Future Fields (Phase 2)
- Related identifiers (DOIs of references)
- Contributors (non-authors)
- Funding information
- Communities
- References/Bibliography

## Component Implementation

### 1. Button Component
**Location**: `extensions/bonfire_open_science/lib/web/components/zenodo_doi_button_live.ex`

```elixir
defmodule Bonfire.OpenScience.ZenodoDoiButtonLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop post, :map, required: true
  prop current_user, :map, required: true
  prop class, :css_class, default: "btn btn-sm btn-ghost"
end
```

**Template** (`zenodo_doi_button_live.sface`):
```surface
<Bonfire.UI.Common.OpenModalLive
  id="zenodo-doi-modal"
  title_text="Create DOI with Zenodo"
  open_btn_text="Create DOI"
  open_btn_class={@class}
>
  <:open_btn>
    <button class={@class}>
      <Iconify.iconify icon="carbon:cloud-upload" />
      <span>Create DOI</span>
    </button>
  </:open_btn>

  <:default>
    <ZenodoMetadataFormLive 
      post={@post} 
      current_user={@current_user}
      id="zenodo-metadata-form" 
    />
  </:default>
</Bonfire.UI.Common.OpenModalLive>
```

### 2. Modal Form Component
**Location**: `extensions/bonfire_open_science/lib/web/components/zenodo_metadata_form_live.ex`

```elixir
defmodule Bonfire.OpenScience.ZenodoMetadataFormLive do
  use Bonfire.UI.Common.Web, :stateful_component

  prop post, :map, required: true
  prop current_user, :map, required: true

  data metadata, :map, default: %{}
  data creators, :list, default: []
  data errors, :map, default: %{}

  def mount(socket) do
    # Pre-populate metadata from post
    {:ok, socket |> populate_from_post()}
  end

  def handle_event("add_creator", _, socket) do
    # Add new creator to list
  end

  def handle_event("remove_creator", %{"index" => index}, socket) do
    # Remove creator from list
  end

  def handle_event("validate", %{"metadata" => params}, socket) do
    # Validate form data
  end

  def handle_event("submit", %{"metadata" => params}, socket) do
    # Submit to Zenodo API
  end
end
```

### 3. Form Template Structure
**Location**: `zenodo_metadata_form_live.sface`

```surface
<Form for={:metadata} submit="submit" change="validate">
  {!-- Upload Type --}
  <div class="form-control">
    <Label>Upload Type *</Label>
    <Select field={:upload_type} options={upload_type_options()} />
    <ErrorTag field={:upload_type} />
  </div>

  {!-- Title --}
  <div class="form-control">
    <Label>Title *</Label>
    <TextInput field={:title} />
    <ErrorTag field={:title} />
  </div>

  {!-- Creators --}
  <div class="form-control">
    <Label>Authors/Creators *</Label>
    {#for {creator, index} <- Enum.with_index(@creators)}
      <div class="creator-row">
        <TextInput 
          name={"creators[#{index}][name]"} 
          placeholder="Family name, Given names" 
        />
        <TextInput 
          name={"creators[#{index}][orcid]"} 
          placeholder="0000-0000-0000-0000" 
        />
        <button type="button" phx-click="remove_creator" phx-value-index={index}>
          Remove
        </button>
      </div>
    {/for}
    <button type="button" phx-click="add_creator">+ Add Author</button>
  </div>

  {!-- Description --}
  <div class="form-control">
    <Label>Description *</Label>
    <TextArea field={:description} rows="4" />
    <ErrorTag field={:description} />
  </div>

  {!-- Publication Date --}
  <div class="form-control">
    <Label>Publication Date *</Label>
    <DateInput field={:publication_date} />
    <ErrorTag field={:publication_date} />
  </div>

  {!-- Access Rights --}
  <div class="form-control">
    <Label>Access Rights *</Label>
    <RadioGroup field={:access_right} options={access_right_options()} />
  </div>

  {!-- License (conditional) --}
  {#if @metadata.access_right in ["open", "embargoed"]}
    <div class="form-control">
      <Label>License *</Label>
      <Select field={:license} options={license_options()} />
      <a href="https://choosealicense.com" target="_blank">Help choosing</a>
    </div>
  {/if}

  {!-- Keywords --}
  <div class="form-control">
    <Label>Keywords</Label>
    <TextInput field={:keywords} placeholder="keyword1, keyword2, keyword3" />
  </div>

  {!-- Submit --}
  <div class="modal-action">
    <button type="button" class="btn btn-ghost">Cancel</button>
    <Submit class="btn btn-primary">Create DOI</Submit>
  </div>
</Form>
```

## Integration Points

### 1. Post Actions Menu
Add the Zenodo DOI button to post action menus:
- Location: Post dropdown menu or action bar
- Visibility: Show for post authors or users with permission
- Condition: Only show if post doesn't already have a DOI

### 2. Data Flow
```
User clicks "Create DOI" → 
Modal opens with pre-filled data → 
User reviews/edits metadata → 
Form validation → 
Submit to Zenodo API → 
Store DOI in Media.metadata → 
Display success/error → 
Close modal
```

### 3. Metadata Storage
Store Zenodo metadata in `Media.metadata` field:
```elixir
%{
  "zenodo" => %{
    "doi" => "10.5281/zenodo.123456",
    "deposit_id" => "123456",
    "metadata" => %{...submitted metadata...},
    "submitted_at" => datetime,
    "status" => "published"
  }
}
```

## Validation Rules

### Frontend Validation
- Title: Required, 1-500 characters
- Creators: At least one, valid name format
- Description: Required, min 10 characters
- Publication date: Valid date, not future
- ORCID: Format `0000-0000-0000-000X` if provided

### Backend Validation
- Verify user has permission to create DOI
- Check post doesn't already have DOI
- Validate against Zenodo schema
- Handle API response errors

## UI/UX Considerations

### Loading States
- Show spinner during API submission
- Disable form during processing
- Progress indicator for multi-step process

### Error Handling
- Inline field validation errors
- API error messages in alert
- Retry mechanism for failures

### Success Feedback
- Show DOI with copy button
- Link to Zenodo record
- Option to view/download citation

### Responsive Design
- Modal adapts to mobile screens
- Scrollable content area
- Touch-friendly controls

## Configuration

Add to `runtime_config.ex`:
```elixir
config :bonfire_open_science, :zenodo,
  api_url: System.get_env("ZENODO_API_URL", "https://sandbox.zenodo.org/api"),
  access_token: System.get_env("ZENODO_ACCESS_TOKEN"),
  default_community: System.get_env("ZENODO_COMMUNITY"),
  default_license: System.get_env("ZENODO_DEFAULT_LICENSE", "CC-BY-4.0")
```

## Testing Strategy

### Unit Tests
- Metadata extraction from posts
- Form validation logic
- API payload generation

### Integration Tests
- Modal opening/closing
- Form submission flow
- Error handling scenarios

### Manual Testing Checklist
- [ ] Modal opens with pre-filled data
- [ ] Can add/remove multiple creators
- [ ] Validation shows appropriate errors
- [ ] License field appears conditionally
- [ ] Successful submission stores DOI
- [ ] Error messages display correctly
- [ ] Modal closes after success

## API Integration Notes

### Zenodo Sandbox
- Use sandbox for development: https://sandbox.zenodo.org
- Separate access token required
- DOIs created are not permanent

### Rate Limiting
- Implement exponential backoff
- Cache successful submissions
- Queue for bulk operations

## Future Enhancements

### Phase 2
- Bulk DOI creation for multiple posts
- DOI versioning for updated posts
- Citation format generator
- Integration with reference manager tools
- Auto-populate from ORCID profile
- Community selection
- Embargo date picker
- File attachment support

### Phase 3
- Automated DOI creation on publish
- Sync with Zenodo for updates
- Citation metrics display
- Related identifiers linking
- Grant/funding information
- Custom metadata schemas

## Resources

- [Zenodo API Documentation](https://developers.zenodo.org/)
- [Zenodo Sandbox](https://sandbox.zenodo.org)
- [Metadata Schema Reference](https://developers.zenodo.org/#deposit-metadata)
- [REST API Reference](https://developers.zenodo.org/#rest-api)
- [ORCID Integration Guide](https://info.orcid.org/documentation/)

## Notes

- Zenodo provides free DOI minting (unlike Crossref)
- Sandbox environment perfect for testing
- Consider DataCite as alternative provider
- Modal pattern reusable for other metadata forms