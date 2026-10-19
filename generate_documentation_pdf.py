from pathlib import Path
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import cm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, Table, TableStyle, KeepTogether

OUT = Path(__file__).parent / "output" / "pdf" / "My_Eyes_Technical_Documentation.pdf"
OUT.parent.mkdir(parents=True, exist_ok=True)

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(name="Title2", parent=styles["Title"], fontName="Helvetica-Bold", fontSize=27, leading=34, textColor=colors.HexColor("17365D"), alignment=TA_CENTER, spaceAfter=12))
styles.add(ParagraphStyle(name="Sub", parent=styles["Normal"], fontSize=12, leading=17, textColor=colors.HexColor("4B5563"), alignment=TA_CENTER))
styles.add(ParagraphStyle(name="H1x", parent=styles["Heading1"], fontName="Helvetica-Bold", fontSize=17, leading=22, textColor=colors.HexColor("17365D"), spaceBefore=12, spaceAfter=8))
styles.add(ParagraphStyle(name="H2x", parent=styles["Heading2"], fontName="Helvetica-Bold", fontSize=12.5, leading=16, textColor=colors.HexColor("1F4E79"), spaceBefore=8, spaceAfter=5))
styles.add(ParagraphStyle(name="Bodyx", parent=styles["BodyText"], fontSize=9.4, leading=14, spaceAfter=6))
styles.add(ParagraphStyle(name="Small", parent=styles["BodyText"], fontSize=7.8, leading=10.5, spaceAfter=3))

def P(x, style="Bodyx"): return Paragraph(x, styles[style])
def H(x, level=1): return P(x, "H1x" if level == 1 else "H2x")
def bullets(items): return [P("• " + x) for x in items]
def table(headers, rows, widths=None):
    data = [[P(h, "Small") for h in headers]] + [[P(str(c), "Small") for c in row] for row in rows]
    t = Table(data, colWidths=widths, repeatRows=1, hAlign="LEFT")
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,0), colors.HexColor("17365D")), ("TEXTCOLOR", (0,0), (-1,0), colors.white),
        ("FONTNAME", (0,0), (-1,0), "Helvetica-Bold"), ("GRID", (0,0), (-1,-1), .25, colors.HexColor("B8C7D9")),
        ("VALIGN", (0,0), (-1,-1), "TOP"), ("LEFTPADDING", (0,0), (-1,-1), 5), ("RIGHTPADDING", (0,0), (-1,-1), 5),
        ("TOPPADDING", (0,0), (-1,-1), 4), ("BOTTOMPADDING", (0,0), (-1,-1), 4),
        ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("F4F8FC")]),
    ]))
    return t

def footer(canvas, doc):
    canvas.saveState(); canvas.setStrokeColor(colors.HexColor("B8C7D9")); canvas.line(2*cm, 1.4*cm, 19*cm, 1.4*cm)
    canvas.setFont("Helvetica", 8); canvas.setFillColor(colors.HexColor("52606D")); canvas.drawString(2*cm, .9*cm, "My Eyes - Vision Beyond Sight | Technical Documentation")
    canvas.drawRightString(19*cm, .9*cm, f"Page {doc.page}"); canvas.restoreState()

story=[]
story += [Spacer(1, 4*cm), P("MY EYES", "Title2"), P("Vision Beyond Sight", "Title2"), Spacer(1, .35*cm), P("Technical Project Documentation", "Sub"), Spacer(1, 1.1*cm), P("A voice-first, AI-powered mobile accessibility platform for blind and visually impaired users", "Sub"), Spacer(1, 4.5*cm), P("Implementation basis: source tree reviewed in PSG-capstone (Flutter frontend and FastAPI backend).", "Sub"), P("Prepared: 6 October 2026", "Sub"), PageBreak()]

story += [H("Document Status and Reading Guide"), P("This report is implementation-led. Statements labelled <b>Implemented</b> are supported by the repository. <b>Configuration dependent</b> means code exists but a credential, device capability, or external provider is required. <b>Needs verification</b> identifies deployment details that cannot be proven from source alone. This distinction avoids treating planned behavior as delivered behavior."),
H("Abstract"), P("My Eyes - Vision Beyond Sight is a Flutter and FastAPI accessibility application that turns camera or user-selected images into spoken, user-specific assistance. It integrates document OCR, medicine and product reading, currency recognition, object and scene analysis, text-to-speech, voice command routing, biometric-first account access, scan history, emergency SOS, navigation, and AI Help. The design reduces touch dependence by confirming choices and returning understandable speech through an active companion profile, Alex or Maya."),
H("Contents"), P("1 Introduction and problem | 2 Proposed system | 3 Architecture and data flow | 4 User experience | 5 Modules | 6 Backend, API and data | 7 Setup and testing | 8 Quality, limitations and future scope"), PageBreak()]

story += [H("1. Introduction, Problem Statement and Objectives"),
P("Blind and visually impaired people frequently need a second person to read labels, distinguish a banknote, identify nearby items, or interpret a visual scene. Conventional apps often place critical controls behind small, visual, touch-heavy interfaces. Separate single-purpose tools also force users to switch applications and learn inconsistent interaction patterns."),
P("My Eyes addresses this gap with one authenticated, voice-guided mobile application. A user can ask for a task, choose the camera or an existing image, receive a result, hear it through text-to-speech, and later retrieve module-specific history. The intended outcome is greater independence for reading printed text, packaged information, medicine labels, currency, objects, and surroundings."),
H("Objectives",2)] + bullets(["Provide voice-led access to vision functions with clear spoken confirmation and errors.", "Keep camera capture and file selection as separate, reliable input paths.", "Protect personal results through authenticated, user-scoped APIs and history.", "Support selectable companion voices and repeatable instructions.", "Offer safety and mobility support through SOS and voice-guided navigation."])+[H("Scope and target users",2), P("Primary users are blind and visually impaired smartphone users. Sighted helpers may assist during onboarding, permission prompts, or ambiguous results. The system is an assistive tool: it must not be used as the sole source for medical, payment, or emergency-critical decisions.")]

story += [H("2. Proposed System and Verified Feature Set"),
P("The Flutter client provides screens, accessibility semantics, camera/file entry, speech recognition, text-to-speech, and secure token storage. It calls a FastAPI service that validates authenticated requests, delegates to task services and AI/OCR engines, records applicable results, and returns schemas consumed by the client."),
table(["Feature","Status","Purpose / implementation evidence"],[
["Read Text (OCR)","Implemented","/ocr/scan, EasyOCR dependency, OCR engine/service and Read Text screen."],
["Medicine Reader","Implemented","/medicine/scan with medicine engine/service; OCR-led label reading. Not a diagnosis service."],
["Product Reader","Implemented","/product/scan with product reader engine/service for printed package information."],
["Currency","Implemented","/currency/scan with currency engine/service."],
["Object / Scene","Implemented","/objects/detect and /scene/describe; Ultralytics and yolov8n.pt are present."],
["Companions","Implemented","Alex/Maya profiles, change-companion screen, stored profile companion field."],
["History","Implemented","scan_history model, migration, history APIs and module history screens."],
["Biometric-first access","Implemented","device credential model, biometric service and /auth/biometric/login."],
["Google Sign-In","Implemented/configuration dependent","google_sign_in client dependency, setup guide and server google-auth dependency/service; Cloud configuration is required."],
["SOS, navigation, payment QR, AI Help","Implemented/configuration dependent","Dedicated client/backend routes. SOS delivery, Geoapify and Gemini need their respective configuration."],
], [3.1*cm,3.1*cm,10.5*cm]), PageBreak()]

story += [H("3. Complete System Architecture"), P("The application is layered so that user interaction remains in Flutter while processing and persistent data remain on the FastAPI side."),
P("<b>Flutter UI and accessibility</b><br/>Dashboard, onboarding, scanner, history, companion, SOS, navigation and payment screens<br/>↓ voice command service, speech-to-text, TTS, camera/file picker, secure local storage<br/>↓ HTTPS API requests with Bearer token<br/>↓<br/><b>FastAPI API layer</b><br/>routers → dependencies/JWT user resolution → services → AI engines / PostgreSQL<br/>↓<br/><b>Response</b><br/>typed JSON → Flutter result screen → active companion speech → user"),
H("Frontend architecture",2), P("The Flutter application uses Dart. Key source areas include <b>lib/screens</b> for user flows, <b>lib/services</b> for APIs, speech, file picking, biometric flow and storage, <b>lib/core</b> for routing/catalog/theme, and <b>lib/widgets</b> for reusable controls. Dependencies include camera, image_picker, file_picker, speech_to_text, flutter_tts, local_auth, flutter_secure_storage and google_sign_in."),
H("Backend architecture",2), P("FastAPI starts in app/main.py, mounts uploads/audio static folders, registers routers, configures CORS, initializes SQLAlchemy metadata, and installs structured handlers for validation, HTTP, and unexpected errors. Routers are deliberately thin: a route accepts a file/body, obtains the database session and authenticated user, then calls the appropriate service."),
H("Database architecture",2), P("PostgreSQL is the intended datastore through SQLAlchemy and Alembic. The database holds user/account state and application records including scan history, device credentials, emergency contacts/events, saved places, and AI conversations/messages. Production database name and connection value are deployment settings, not hard-coded facts."), PageBreak()]

story += [H("4. End-to-End Data Flow"), P("<b>Startup:</b> Splash screen → auth gate/session coordination → onboarding or dashboard. The dashboard starts voice assistance, exposes cards and repeats instructions through the eye/visibility control. The active companion affects visual theme and spoken output."),
P("<b>Vision module flow:</b> User says or selects a task → module router resolves a VisionMode → app asks camera or file → camera capture or Android Storage Access Framework picker returns bytes → client validates non-empty input → multipart request carrying <b>file</b> and Bearer token → FastAPI dependency resolves current user → service invokes relevant engine → service formats the result and records it where implemented → JSON response → Flutter presents and speaks it."),
table(["User request","Backend route","Processing / result"],[
["Read this text","POST /ocr/scan","OCR extracts printed text; client speaks returned text."],
["Read my medicine","POST /medicine/scan","Medicine service reads supplied label content; user should verify critical details."],
["Read this product","POST /product/scan","Product reader cleans OCR text and returns useful package details when readable."],
["Identify currency","POST /currency/scan","Currency engine identifies a note when confidence/quality permits."],
["What is this?","POST /objects/detect","Object detector returns detected object information."],
["Describe surroundings","POST /scene/describe","Scene engine produces a description from the supplied image."],
], [3.3*cm,4*cm,9.4*cm]),
H("Input separation",2), P("File input does not fall back to a fresh camera capture. VoiceFilePicker calls the platform image picker with <b>withData: true</b>, returns the chosen file bytes and filename, and returns an empty result on cancellation or failure. The client must send those returned bytes to the selected module. Camera flow separately opens/captures, validates, and sends its captured image."), PageBreak()]

story += [H("5. Voice-First Experience, Companions and Instructions"),
P("Speech recognition maps a user phrase to an action through the voice command service/router. TTS then reads instructions, confirmations, results and recovery guidance. The dashboard includes visible controls with semantics as a fallback, but important flows are designed to be navigable by speech."),
H("Companion system",2), P("Two companion profiles are present: Alex and Maya. Selection is available in onboarding and the Change Companion screen. The chosen value is retained in the user profile (users.companion) and is used to resolve presentation and voice behavior; the application function does not change when a companion changes. A successful change should confirm the new companion immediately, then continue the same active flow."),
H("Dashboard instructions",2), P("The dashboard has a visibility/eye icon and a Repeat Instructions action. The guide is built from the module catalog and teaches task selection, camera versus file selection, hearing results, history, companion changes, repeating instructions, accessibility behavior, and what to do after a recognition failure. It is designed to be replayed rather than remembered."),
H("User journey examples",2), table(["Journey","Flow"],[
["First-time user","Splash → account/onboarding → companion choice → instructions → dashboard → spoken welcome."],
["Existing user","Splash/auth gate → biometric/device session as available → dashboard → command or card."],
["Read text","Say ‘read this text’ → select camera/file → submit image → OCR → display + companion speaks result → read-text history."],
["Change Alex to Maya","Dashboard/change screen → select Maya → profile update → confirmation in Maya profile → return to dashboard."],
["Failure","Permission/network/recognition error → concise spoken cause → offer retry, another input source, or cancellation."],
], [3.3*cm,13.4*cm]), PageBreak()]

story += [H("6. Module-by-Module Documentation"),
H("Read Text / OCR",2), P("Input is an image file from the camera or picker. The OCR engine processes readable printed text and the service returns a structured OCR response. The expected spoken behavior is to read the extracted result. If no readable text is found, the client should say so and prompt for better lighting, focus, or another image."),
H("Medicine Reader",2), P("The module sends an image to POST /medicine/scan. It uses the medicine engine/service to read label information available in the image. It should communicate uncertainty and must not make dosage, diagnosis, or treatment claims beyond the returned text. Important medical details require independent verification."),
H("Product Reader",2), P("POST /product/scan routes an image to the product reader. OCR is appropriate for printed product name, dates, ingredients, and other label fields when legible. Text cleaning/filtering is useful to suppress irrelevant fragments; extraction quality depends on the image."),
H("Currency Detection",2), P("POST /currency/scan calls the currency service/engine. The result should be spoken clearly only when the system can identify the note sufficiently. A low-confidence or unrecognised result should request a retake in good light rather than guess."),
H("Object Detection",2), P("POST /objects/detect invokes the object detection service. The repository contains Ultralytics and YOLO weights, supporting object-detection capability. Returned object names and confidence information can be spoken, including multiple detections where the response provides them."),
H("Scene Description",2), P("POST /scene/describe uses the scene service/engine to turn an image into an environment description. The application should state when it cannot form a reliable description and invite another image."),
H("Additional implemented modules",2), P("AI Help has POST/DELETE /ai-help endpoints for conversational help. Smart Navigation exposes saved places, geocoding, nearby search, directions and reverse lookup, using a server-side Geoapify key when configured. Emergency contacts and SOS events are user-scoped. Payment scanning is a Flutter feature with UPI parsing/services; payment confirmation must remain deliberate and secure."), PageBreak()]

story += [H("7. History, Authentication and Security"),
H("Module history",2), P("A scan history record holds id, user_id, scan_type, optional input_image path, result, and created_at. The history UI includes a picker and a module history screen. A module-specific query uses scan_type so, for example, OCR history is not mixed with currency history. The composite index ix_scan_history_user_type_created supports newest-first per-user/per-module retrieval."),
H("Authentication",2), P("The backend issues HS256 JWT access tokens with a 30-minute expiry after account/device authentication. Protected routes use OAuth2 Bearer token extraction and current-user resolution. Password utilities use pwdlib’s recommended password hashing. New biometric-first accounts may have no password; legacy hashed-password accounts remain supported. The client uses local_auth and flutter_secure_storage. Google Sign-In code and setup documentation exist, but it requires Android/Google Cloud client configuration and server-side ID-token verification setup."),
H("Security notes",2), P("The repository’s security module currently defines a literal JWT secret; this is suitable only for local development and should be moved to a private environment variable before release. The .env.example correctly keeps database URLs, Gemini, Geoapify and SOS credentials as placeholders. Input validation, authenticated routes, user-scoped records and structured errors are implemented foundations; TLS, deployment secrets, rate limiting and restrictive production CORS need deployment verification."),
H("Error handling and recovery",2), table(["Condition","System response and user feedback","Recovery"],[
["Camera/file permission or cancellation","Do not crash; return to the flow with a spoken cancellation/failure message.","Grant permission, choose file again, or use camera."],
["Empty/unsupported image","Reject before or at API validation; explain image was unusable.","Select/capture a valid image."],
["OCR/detection uncertainty","Return no-result/low-confidence outcome rather than invent a result.","Improve lighting, focus, framing; retry."],
["Network/API unavailable","Client surfaces API error; FastAPI structured envelope handles validation/HTTP/unhandled failures.","Check connection and retry later."],
["Expired/invalid token","Protected dependency rejects request.","Re-authenticate, then repeat request."],
["TTS/speech failure","Keep readable on-screen result and report speech unavailability.","Retry speech or use controls."],
], [3.3*cm,8*cm,5.4*cm]), PageBreak()]

story += [H("8. API Documentation"), P("All routes below are verified from router declarations. Most vision routes require an Authorization: Bearer token and multipart field <b>file</b>. Exact response field names are defined in app/schemas and should be used by clients rather than inferred."),
table(["Method and endpoint","Auth","Purpose / request"],[
["POST /auth/register","No","Create account; AccountSession response (201)."],
["POST /auth/account/status","No","Check device/account status."],
["POST /auth/account/link","No/flow-specific","Link device/account session."],
["POST /auth/biometric/login","No/credential flow","Obtain AccountSession after device credential verification."],
["GET /profile/me","Bearer","Return current UserResponse."],
["PUT /profile/companion","Bearer","Persist active companion."],
["PUT /profile/update; /change-password","Bearer","Update profile or legacy password."],
["POST /ocr/scan; /medicine/scan; /product/scan; /currency/scan","Bearer","Multipart file submitted to named vision service."],
["POST /objects/detect; /scene/describe","Bearer","Multipart file for object or scene result."],
["POST /history/save; GET /history/all,/types,/module/{scan_type}","Bearer","Create/list/filter user scan records."],
["GET/POST/PUT/DELETE /emergency-contacts...","Bearer","Manage emergency contacts and primary contact."],
["GET /sos/status; POST /sos/trigger; POST/GET /sos-events","Bearer","SOS readiness, delivery trigger and user event records."],
["POST /tts/generate","Needs verification","Generate TTS response; check schema for exact payload."],
["POST /ai-help; DELETE /ai-help/{conversation_id}","Bearer","AI Help conversation operations."],
["GET/POST/PUT/DELETE /navigation/saved-places; GET geocode, nearby, categories, directions, reverse","Bearer","Navigation and place support."],
], [6.2*cm,2*cm,8.5*cm]),
H("Example vision request",2), P("<font face='Courier'>POST /ocr/scan<br/>Authorization: Bearer &lt;access_token&gt;<br/>Content-Type: multipart/form-data<br/>file=@label.jpg</font>"), P("Expected behavior: a validated response matching OCRResponse. Possible status categories include success, validation error (422), authentication failure (401), missing resource (404), and controlled/unexpected server error (5xx). The central error handlers use a clean success:false error envelope for error conditions."), PageBreak()]

story += [H("9. Database and Migration Design"),
table(["Table/model","Key verified fields / role"],[
["users","id PK; full_name; unique email; nullable password; phone_number; companion; created_at. Owns history, device credentials, contacts, SOS events, conversations and saved places."],
["scan_history","id PK; user_id FK users.id ON DELETE CASCADE; scan_type; input_image; result; created_at. Composite per-user/type/time index."],
["device_credentials","Biometric/passwordless device credential model present; exact schema in model source."],
["emergency_contacts, sos_events","Emergency destination and event records; migration adds readiness fields."],
["saved_places","Navigation persistence model."],
["ai_conversations, ai_messages","AI Help conversation persistence models."],
], [5*cm,11.7*cm]),
P("<b>ER-style view</b><br/>users (1) ──&lt; scan_history<br/>users (1) ──&lt; device_credentials<br/>users (1) ──&lt; emergency_contacts ──&lt; sos_events<br/>users (1) ──&lt; saved_places<br/>users (1) ──&lt; ai_conversations ──&lt; ai_messages"),
H("Migrations",2), P("Alembic is configured through alembic.ini, alembic/env.py and version scripts. The scan_history migration c721dc2f90ab creates the table, its user foreign key and index. Later migrations cover saved places, emergency contacts/events, biometric devices, AI conversations/messages and SOS/history readiness. Standard workflow: set DATABASE_URL, run <font face='Courier'>alembic upgrade head</font>, then generate reviewed schema changes with Alembic revision tooling. The application additionally performs limited startup column compatibility checks; that is a resilience measure, not a replacement for migrations."),
H("Environment configuration",2), P("Place .env in <font face='Courier'>PSG-capstone/app/.env</font>. Required/optional names evidenced by .env.example include DATABASE_URL, GOOGLE_OAUTH_WEB_CLIENT_ID, GEMINI_API_KEY, GEMINI_MODEL, GEOAPIFY_API_KEY, EMERGENCY_ALERT_WEBHOOK_URL, EMERGENCY_ALERT_WEBHOOK_TOKEN and EMERGENCY_ALERT_TIMEOUT. Never commit real values."), PageBreak()]

story += [H("10. Folder Structure and Installation"),
P("<b>Known implementation structure</b><br/><font face='Courier'>PSG-capstone/app/</font> main.py, routers/, services/, ai/, models/, schemas/, database/, security.py, dependencies.py, error_handlers.py<br/><font face='Courier'>PSG-capstone/alembic/</font> env.py and versions/<br/><font face='Courier'>PSG-capstone/frontend/lib/</font> main.dart, screens/, services/, core/, models/, widgets/<br/><font face='Courier'>PSG-capstone/frontend/test/</font> voice command, UPI, route geometry and long-press tests."),
H("Development setup",2), table(["Step","Command / action"],[
["Prerequisites","Install Python, PostgreSQL, Flutter/Dart, Android Studio + SDK, Git and a physical Android device/emulator."],
["Backend environment","Create/activate a virtual environment; install dependencies from app/requirements.txt."],
["Configure","Copy app/.env.example to app/.env; set DATABASE_URL and only the external keys required for the features being tested."],
["Migrate","From PSG-capstone, run alembic upgrade head after PostgreSQL is available."],
["Start backend","From PSG-capstone: py -m uvicorn app.main:app --reload"],
["Frontend packages","From PSG-capstone/frontend: flutter pub get"],
["Run frontend","Connect device/emulator and run flutter run. Ensure its API base URL reaches the backend from the device."],
], [4*cm,12.7*cm]),
H("Startup behavior",2), P("The splash screen provides branding and an opportunity to coordinate session/auth routing before the dashboard appears. Production builds should avoid exposing raw startup exceptions: log safe diagnostics server-side, show concise user-facing spoken guidance, and offer retry rather than a stack trace."), PageBreak()]

story += [H("11. Testing Strategy and Demo Flow"),
P("Testing should combine existing Flutter tests with backend API and device-level testing. Do not record unmeasured performance claims; record actual results in the Actual Result column during test execution."),
table(["ID","Feature / input","Expected result","Actual / status"],[
["TC-01","Valid printed label → OCR","Text response is shown/spoken; correct user history entry if saved.","To execute"],
["TC-02","Blurry/blank image → OCR","No fabricated text; clear spoken retry guidance.","To execute"],
["TC-03","Product/medicine/currency sample","Correct service route and a useful, confidence-aware response.","To execute"],
["TC-04","Object/scene photo","Detection/description returned; multi-result layout remains accessible.","To execute"],
["TC-05","Choose image file","Exactly selected bytes are processed; no camera capture occurs.","To execute"],
["TC-06","Expired token","Protected request rejected; app requests authentication.","To execute"],
["TC-07","History filter","Only current user + chosen scan type are listed newest first.","To execute"],
["TC-08","Companion change","Profile persists; next spoken interaction uses selected companion.","To execute"],
["TC-09","Offline/API timeout","Understandable spoken recovery, no app crash.","To execute"],
["TC-10","SOS setup / trigger","Contacts/readiness and delivery fallback are clearly reported.","To execute"],
], [1.3*cm,4.6*cm,7.2*cm,3.6*cm]),
H("Presentation demo",2), P("Launch → splash/auth → explain Alex/Maya selection → dashboard voice prompt → read a label → identify a package/currency/object → describe a scene → open module history → replay instructions → switch companion → show file picker path → demonstrate a failed image and retry guidance → conclude with SOS/navigation/AI Help as configured features. Use pretested sample images, a reachable backend, and clear disclosure of any missing external keys."), PageBreak()]

story += [H("12. Performance, Limitations and Future Enhancements"),
H("Performance and reliability",2), P("No benchmark numbers are claimed. Measure end-to-end time separately for image acquisition, upload, backend inference, database write, response parsing and TTS start. Test poor network conditions, oversized images, repeated scans, database outages and unavailable external integrations. Image size optimization should preserve text legibility for OCR."),
H("Known limitations",2)] + bullets(["OCR and recognition are sensitive to blur, glare, low lighting, perspective, resolution and unusual fonts.", "Object and scene models can be uncertain, incomplete or contextually wrong; outputs require cautious wording.", "Some capabilities depend on network access and configured third-party credentials (Gemini, Geoapify, SOS delivery, Google Sign-In).", "Medicine and payment results are assistive information, not medical advice or an authorization to transact.", "Voice recognition, TTS availability and device permission behavior vary by Android device and language."])+[
H("Future enhancements",2)] + bullets(["Offline/on-device OCR and selected vision models; multilingual speech and OCR.", "Expanded currency and medicine reference support with auditable confidence/verification flows.", "More robust scene understanding, wearable/smart-glasses integration and personalized voice prompts.", "Accessible location assistance, emergency workflows, privacy hardening, monitoring and production rate limiting.", "Formal usability testing with visually impaired participants and regression test automation."])+[
H("Technology stack",2), table(["Technology","Verified use"],[
["Flutter / Dart","Android mobile client, screens, services and accessibility UI."], ["Python / FastAPI","Backend API, routes, schemas, dependencies and error handling."], ["PostgreSQL / SQLAlchemy / Alembic","Persistent relational data, ORM and migrations."], ["JWT / pwdlib / local_auth","Session token, password hashing and client biometric access."], ["EasyOCR / OpenCV / Ultralytics","OCR and computer-vision processing dependencies; YOLO weights present."], ["flutter_tts / speech_to_text","Spoken output and voice command input."], ["Google services / Geoapify","Configuration-dependent identity, AI Help and navigation integrations."],
], [5.6*cm,11.1*cm]),
H("Conclusion"), P("My Eyes combines mobile accessibility design, computer vision, OCR, voice interaction, secure user data and a service-oriented backend into one assistive platform. Its core strength is the connection between input choice, authenticated processing, understandable results and repeatable speech guidance. Continued testing with real users, careful confidence handling and secure production deployment are essential to make that promise dependable in everyday use."),
H("References"), P("Repository source reviewed: PSG-capstone/app, PSG-capstone/alembic and PSG-capstone/frontend (local project source). Technology configuration references are documented in app/.env.example, app/requirements.txt, frontend/pubspec.yaml and frontend setup documents. External service capabilities must be verified against their current official documentation before deployment.")]

doc=SimpleDocTemplate(str(OUT), pagesize=A4, rightMargin=2*cm,leftMargin=2*cm,topMargin=1.7*cm,bottomMargin=1.8*cm, title="My Eyes - Technical Documentation", author="My Eyes Project")
doc.build(story, onFirstPage=footer, onLaterPages=footer)
print(OUT)
