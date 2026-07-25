# Attachment System

**Date:** July 11, 2026  
**Status:** Complete  
**Purpose:** Manage file attachments for communications without storing BLOBs in the database

---

## 🎯 Design Philosophy

**Never store BLOBs in the database!** Instead:
- Store files in a local folder structure (or S3/ADFS in production)
- Store **references** (URLs/paths) in the `attachments` JSONB column
- Maintain metadata (size, type, upload time) in the database

---

## 📁 Directory Structure

```
attachments/
└── communications/
    ├── 1/
    │   ├── 20260711_103045_contract.pdf
    │   └── 20260711_104512_photo.jpg
    ├── 2/
    │   └── 20260711_111234_invoice.pdf
    └── 7/
        └── 20260711_113143_test_invoice.pdf
```

Each communication gets its own folder named after the communication ID.

---

## 🔧 Components

### 1. **AttachmentManager** (`tools/attachment_manager.py`)

Handles file storage and retrieval.

**Features:**
- ✅ Creates communication-specific directories
- ✅ Validates file size and type
- ✅ Sanitizes filenames (prevents directory traversal)
- ✅ Generates unique filenames (timestamp + original name)
- ✅ Returns metadata for database storage
- ✅ Supports cleanup when communications are deleted

**Usage:**
```python
from tools.attachment_manager import AttachmentManager

manager = AttachmentManager()  # Defaults to attachments/communications

# Save a file
metadata = manager.save_attachment(
    communication_id=123,
    source_path="/path/to/file.pdf",
    original_name="contract.pdf",
    file_type="contract"
)

# Returns:
{
    "type": "contract",
    "url": "file://123/20260711_103045_contract.pdf",
    "name": "contract.pdf",
    "stored_name": "20260711_103045_contract.pdf",
    "size": 10240,
    "mime_type": "application/pdf",
    "uploaded_at": "2026-07-11T10:30:45.123456"
}
```

### 2. **CommunicationLogger Integration** (`agents/communication_logger.py`)

Automatically processes attachments when logging communications.

**Usage:**
```python
logger = CommunicationLogger()

# Log with file paths
comm_id = logger.log_communication(
    entity_id=1,
    communication_type='email',
    summary='Customer sent invoice',
    attachments=[
        "/path/to/invoice.pdf",
        "/path/to/photo.jpg"
    ]
)

# Or with pre-built metadata
comm_id = logger.log_communication(
    entity_id=1,
    communication_type='email',
    summary='Customer sent invoice',
    attachments=[
        {
            "type": "invoice",
            "url": "s3://bucket/invoice.pdf",
            "name": "invoice.pdf",
            "size": 10240
        }
    ]
)
```

---

## 📊 Database Schema

The `attachments` column in `communications` table stores JSONB:

```json
[
  {
    "type": "contract",
    "url": "file://123/20260711_103045_contract.pdf",
    "name": "contract.pdf",
    "stored_name": "20260711_103045_contract.pdf",
    "size": 10240,
    "mime_type": "application/pdf",
    "uploaded_at": "2026-07-11T10:30:45.123456"
  },
  {
    "type": "photo",
    "url": "file://123/20260711_104512_defect.jpg",
    "name": "defect.jpg",
    "stored_name": "20260711_104512_defect.jpg",
    "size": 204800,
    "mime_type": "image/jpeg",
    "uploaded_at": "2026-07-11T10:45:12.654321"
  }
]
```

---

## 🔒 Security Features

### File Validation
- **Size limit:** 50MB default (configurable)
- **Allowed extensions:** PDF, DOC, DOCX, TXT, JPG, JPEG, PNG, GIF, XLSX, CSV, ZIP
- **MIME type detection:** Basic mapping based on extension

### Filename Sanitization
- Removes path components (prevents `../../../etc/passwd` attacks)
- Removes special characters
- Limits filename length to 100 characters
- Replaces spaces with underscores

### Directory Structure
- Each communication gets isolated folder
- No directory traversal possible
- Easy cleanup when communication is deleted

---

## 🚀 Future Enhancements

### S3/ADFS Integration

To switch from local to cloud storage:

```python
# In attachment_manager.py
class AttachmentManager:
    def __init__(self, storage_type='local', config=None):
        if storage_type == 's3':
            self.storage = S3Storage(config)
        elif storage_type == 'adfs':
            self.storage = ADFSStorage(config)
        else:
            self.storage = LocalStorage(config)
```

The JSONB `attachments` column remains the same - only the storage backend changes.

---

## 📝 Usage Examples

### Example 1: Email with Multiple Attachments

```python
logger.log_communication(
    entity_id=105,
    contact_id=42,
    communication_type='email',
    direction='inbound',
    subject='Product Defect Report',
    summary='Customer reported defect with photos attached',
    attachments=[
        "/uploads/defect_photo1.jpg",
        "/uploads/defect_photo2.jpg",
        "/uploads/warranty_card.pdf"
    ]
)
```

**Result:**
- Creates folder `attachments/communications/{comm_id}/`
- Saves 3 files with timestamps
- Stores JSONB metadata in database

### Example 2: Retrieve Attachment

```python
# Get attachment metadata from database
cursor.execute("""
    SELECT attachments FROM agent_first_erp_crm.communications 
    WHERE id = %s
""", (comm_id,))

attachments = cursor.fetchone()[0]

# Access file
for att in attachments:
    file_path = manager.get_attachment_path(
        communication_id=comm_id,
        stored_name=att['stored_name']
    )
    # Process file...
```

---

## ✅ Verification

**Test Results:**
- ✅ Directory structure created: `attachments/communications/`
- ✅ File saved successfully: `20260711_113143_test_invoice.pdf`
- ✅ Metadata stored in database: JSONB array with file details
- ✅ Cleanup works: Files removed when communication deleted

---

## 📁 Files Created

- `tools/attachment_manager.py` - Core attachment management
- `agents/communication_logger.py` - Updated with attachment support
- `attachments/communications/` - Local storage directory
- `docs/ATTACHMENT_SYSTEM.md` - This documentation

---

**Status:** Production-ready for development. Easy to swap to S3/ADFS in production.
