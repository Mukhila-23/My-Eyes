"""Centralized, structured error responses for the My Eyes API.

The Flutter client parses these so a blind user receives short, calm,
non-technical messages instead of raw Pydantic/FastAPI internals.
"""

import logging

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger("myeyes")


def error_response(
    status_code: int,
    code: str,
    message: str,
    hint: str = "",
) -> JSONResponse:
    """Build a consistent {success:false, error:{code,message}} body.

    `hint` is optional developer-facing detail (never a secret) that lets the
    real cause reach the log and the client debug log instead of being hidden
    behind a generic message.
    """
    error = {
        "code": code,
        "message": message,
    }
    if hint:
        error["hint"] = hint
    return JSONResponse(
        status_code=status_code,
        content={
            "success": False,
            "error": error,
        },
    )


def _first_validation_message(exc: RequestValidationError) -> str:
    """Derive one human-readable line from FastAPI's validation errors."""
    errors = exc.errors()
    if not errors:
        return "The request was not valid."

    first = errors[0]
    loc = first.get("loc", ())
    field = ".".join(str(part) for part in loc if part not in ())
    msg = first.get("msg", "invalid input")
    context = first.get("ctx") or {}
    input_value = context.get("error") or context.get("input")

    detail = str(msg)
    if input_value is not None:
        detail = f"{detail} ({input_value})"

    if field and field not in ("body", "query", "path"):
        detail = f"{detail} for field '{field}'"

    return detail


async def validation_error_handler(
    request: Request,
    exc: RequestValidationError,
) -> JSONResponse:
    detail = _first_validation_message(exc)
    logger.warning("Validation failed on %s %s: %s",
                   request.method, request.url.path, detail)
    return error_response(422, "VALIDATION_ERROR", detail)


async def http_exception_handler(
    request: Request,
    exc: StarletteHTTPException,
) -> JSONResponse:
    # A route may raise HTTPException with a structured detail
    # {"code", "message", "hint"} to surface a precise, non-generic cause.
    detail = exc.detail
    if isinstance(detail, dict):
        code = str(detail.get("code") or "REQUEST_ERROR")
        message = str(detail.get("message") or "").strip()
        hint = str(detail.get("hint") or "").strip()
        if not message:
            message = "The request could not be completed."
        logger.warning(
            "%s %s -> %s [%s]: %s",
            request.method, request.url.path, exc.status_code, code, hint or message,
        )
        return error_response(exc.status_code, code, message, hint)

    message = detail
    if not isinstance(message, str) or not message:
        message = "The request could not be completed."
    logger.info("%s %s -> %s: %s",
                request.method, request.url.path, exc.status_code, message)
    return error_response(
        exc.status_code,
        "REQUEST_ERROR",
        message,
    )


async def unhandled_exception_handler(
    request: Request,
    exc: Exception,
) -> JSONResponse:
    logger.exception(
        "Unhandled error on %s %s", request.method, request.url.path
    )
    # Never leak stack traces to the client.
    return error_response(
        500,
        "INTERNAL_ERROR",
        "Something went wrong on our side. Please try again.",
    )
