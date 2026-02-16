package com.omkar.patient_service.exception;

public class EmailAlreadyExistsException extends RuntimeException {
    public EmailAlreadyExistsException(String messagge) {
        super(messagge);
    }
}
