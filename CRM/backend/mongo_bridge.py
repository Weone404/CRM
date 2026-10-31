import os
import logging
import re
from datetime import datetime
from typing import Optional
from pymongo import MongoClient
from database import get_db
from lead_ingestion import normalize_phone
import json

logger = logging.getLogger(__name__)

def get_mongo_client() -> Optional[MongoClient]:
    """Get MongoDB Atlas client (read-only)"""
    mongo_uri = os.getenv('MONGODB_ATLAS_URI')
    if not mongo_uri:
        logger.warning("MONGODB_ATLAS_URI not set, skipping MongoDB import")
        return None
    
    try:
        client = MongoClient(mongo_uri, serverSelectionTimeoutMS=5000)
        client.admin.command('ping')
        return client
    except Exception as e:
        logger.error(f"Failed to connect to MongoDB Atlas: {e}")
        return None

def parse_source_field(source: str) -> tuple:
    """Parse source field into utm components
    Examples:
      'popup - /pilot-training-in-kolkata' -> ('website', 'popup', '/pilot-training-in-kolkata')
      'contact-form' -> ('website', 'form', None)
    """
    if not source:
        return ('website', None, None)
    
    parts = source.split(' - ', 1)
    utm_medium = parts[0].strip() if parts else None
    utm_campaign = parts[1].strip() if len(parts) > 1 else None
    
    return ('website', utm_medium, utm_campaign)

def map_mongo_to_lead(doc: dict) -> dict:
    """Map MongoDB document to Postgres lead schema"""
    # Normalize phone to E.164 format
    raw_phone = doc.get('phone', '')
    normalized_phone = normalize_phone(raw_phone)
    
    # Parse source field
    utm_source, utm_medium, utm_campaign = parse_source_field(doc.get('source', ''))
    
    # Map course to course_interest
    course = doc.get('course', '')
    
    # Get timestamp
    created_at = doc.get('createdAt')
    if isinstance(created_at, dict) and '$date' in created_at:
        created_at = created_at['$date']
    
    return {
        'name': doc.get('name', '').strip(),
        'phone': normalized_phone,
        'email': doc.get('email', '').strip().lower() or None,
        'course_interest': course or 'General Inquiry',
        'utm_source': utm_source,
        'utm_medium': utm_medium,
        'utm_campaign': utm_campaign,
        'address': doc.get('message', '').strip() or None,  # Store message in address field
        'created_at': created_at,
        'mongo_id': str(doc.get('_id', ''))
    }

def get_watermark():
    """Get last import watermark"""
    with get_db() as conn:
        cur = conn.cursor()
        
        # Initialize watermark table if needed
        cur.execute("""
            INSERT INTO mongo_import_watermark (collection_name, last_imported_at, last_imported_id)
            VALUES ('website_leads', NULL, NULL)
            ON CONFLICT (collection_name) DO NOTHING
        """)
        
        cur.execute("""
            SELECT last_imported_at, last_imported_id
            FROM mongo_import_watermark
            WHERE collection_name = 'website_leads'
        """)
        row = cur.fetchone()
        return row if row else (None, None)

def update_watermark(last_timestamp, last_id):
    """Update import watermark"""
    with get_db() as conn:
        cur = conn.cursor()
        cur.execute("""
            UPDATE mongo_import_watermark
            SET last_imported_at = %s,
                last_imported_id = %s,
                updated_at = NOW()
            WHERE collection_name = 'website_leads'
        """, (last_timestamp, last_id))

def upsert_lead(lead_data: dict) -> tuple:
    """Upsert lead into Postgres, return (lead_id, is_new)"""
    with get_db() as conn:
        cur = conn.cursor()
        
        # Check for existing lead by dedup_key (normalized phone)
        dedup_key = lead_data['phone']
        
        cur.execute("""
            SELECT id FROM lead WHERE dedup_key = %s
        """, (dedup_key,))
        
        existing = cur.fetchone()
        
        if existing:
            # Update existing lead (preserve original created_at)
            cur.execute("""
                UPDATE lead
                SET name = COALESCE(%s, name),
                    email = COALESCE(%s, email),
                    course_interest = COALESCE(%s, course_interest),
                    address = COALESCE(%s, address),
                    utm_source = COALESCE(%s, utm_source),
                    utm_medium = COALESCE(%s, utm_medium),
                    utm_campaign = COALESCE(%s, utm_campaign)
                WHERE id = %s
            """, (
                lead_data['name'] or None,
                lead_data['email'],
                lead_data['course_interest'],
                lead_data['address'],
                lead_data['utm_source'],
                lead_data['utm_medium'],
                lead_data['utm_campaign'],
                existing[0]
            ))
            return (str(existing[0]), False)
        else:
            # Insert new lead
            cur.execute("""
                INSERT INTO lead (
                    name, phone, email, course_interest, address,
                    utm_source, utm_medium, utm_campaign, dedup_key, status
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
            """, (
                lead_data['name'],
                lead_data['phone'],
                lead_data['email'],
                lead_data['course_interest'],
                lead_data['address'],
                lead_data['utm_source'],
                lead_data['utm_medium'],
                lead_data['utm_campaign'],
                dedup_key,
                'new'
            ))
            lead_id = cur.fetchone()[0]
            return (str(lead_id), True)

def import_from_mongodb():
    """Import new leads from MongoDB Atlas"""
    client = get_mongo_client()
    if not client:
        return
    # Runs every 60s; 150s lease keeps one instance as the importer while it lives.
    # Taken after the client check so an instance without Mongo configured never
    # holds the lease and blocks an instance that has it.
    from job_lease import acquire_lease
    if not acquire_lease('mongo_import', 150):
        client.close()
        return
    
    try:
        db_name = os.getenv('MONGODB_DATABASE', 'weoneaviation')
        collection_name = os.getenv('MONGODB_COLLECTION', 'leads')
        
        db = client[db_name]
        collection = db[collection_name]
        
        # Get watermark
        last_timestamp, last_id = get_watermark()
        
        # Query for documents newer than watermark
        query = {}
        if last_timestamp:
            # Make watermark timezone-naive for comparison
            if last_timestamp.tzinfo:
                last_timestamp = last_timestamp.replace(tzinfo=None)
            query['createdAt'] = {'$gt': last_timestamp}
        
        # Sort by createdAt ascending to process in order
        cursor = collection.find(query).sort('createdAt', 1).limit(1000)
        
        imported_count = 0
        deduped_count = 0
        last_doc_timestamp = last_timestamp
        last_doc_id = last_id
        
        for doc in cursor:
            try:
                lead_data = map_mongo_to_lead(doc)
                
                if not lead_data['phone']:
                    logger.warning(f"Skipping lead with invalid phone: {doc}")
                    continue
                
                lead_id, is_new = upsert_lead(lead_data)
                
                if is_new:
                    imported_count += 1
                else:
                    deduped_count += 1
                
                # Update watermark tracking
                doc_timestamp = doc.get('createdAt')
                if isinstance(doc_timestamp, datetime):
                    last_doc_timestamp = doc_timestamp
                    last_doc_id = str(doc.get('_id'))
                
            except Exception as e:
                logger.error(f"Failed to import lead from MongoDB: {doc}, error: {e}")
                continue
        
        # Update watermark if we processed any documents
        if last_doc_timestamp and last_doc_timestamp != last_timestamp:
            update_watermark(last_doc_timestamp, last_doc_id)
        
        # Log to audit_log
        if imported_count > 0 or deduped_count > 0:
            with get_db() as conn:
                cur = conn.cursor()
                cur.execute("""
                    INSERT INTO audit_log (actor, action, entity, payload)
                    VALUES (%s, %s, %s, %s)
                """, (
                    None,
                    'mongo_import',
                    'lead',
                    json.dumps({
                        'imported': imported_count,
                        'deduped': deduped_count,
                        'last_timestamp': last_doc_timestamp.isoformat() if last_doc_timestamp else None
                    })
                ))
            
            logger.info(f"MongoDB import: {imported_count} new, {deduped_count} deduped")
        
    except Exception as e:
        logger.error(f"MongoDB import failed: {e}")
    finally:
        client.close()

def start_mongo_bridge():
    """Start MongoDB bridge poller (call from main.py lifespan)"""
    from apscheduler.schedulers.background import BackgroundScheduler
    
    scheduler = BackgroundScheduler()
    scheduler.add_job(
        import_from_mongodb,
        'interval',
        seconds=60,
        id='mongo_bridge',
        replace_existing=True
    )
    scheduler.start()
    logger.info("MongoDB bridge started (polling every 60s)")
    return scheduler
