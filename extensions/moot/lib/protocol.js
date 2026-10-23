export class MootError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
export function requireValue(condition, code, message) { if (!condition) throw new MootError(code, message); }
export function validateRequest(request) {
  requireValue(request?.protocolVersion === 1, 'incompatibleProtocol', 'Unsupported protocol version');
  requireValue(typeof request.requestID === 'string' && request.requestID.length > 0, 'invalidRequest', 'Request ID required');
  requireValue(typeof request.operation === 'string', 'invalidRequest', 'Operation required');
}
