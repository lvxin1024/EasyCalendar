"""Application-layer errors independent of HTTP and concrete storage."""


class ApplicationError(RuntimeError):
    """Base error for use-case failures safe to expose through adapters."""


class InvalidCommandError(ApplicationError):
    """Raised when a command violates domain or use-case rules."""


class ItemNotFoundError(ApplicationError):
    """Raised when an Item is absent or hidden by its lifecycle state."""


class CollectionNotFoundError(ApplicationError):
    """Raised when a command targets an unavailable Collection."""


class SubscriptionNotFoundError(ApplicationError):
    """Raised when a command targets an unavailable Subscription."""


class ReadonlyCollectionError(ApplicationError):
    """Raised when a local edit targets externally owned data."""


class IdempotencyConflictError(ApplicationError):
    """Raised when an idempotency key is reused for a different command."""


class InvalidCursorError(ApplicationError):
    """Raised when a list cursor is malformed or unsupported."""


class ExtractionNotFoundError(ApplicationError):
    """Raised when a persisted Candidate extraction cannot be found."""


class ExtractionRejectedError(ApplicationError):
    """Raised when confirmation targets an already rejected extraction."""


class CandidateDecisionConflictError(ApplicationError):
    """Raised when one Candidate is confirmed with incompatible edits twice."""
