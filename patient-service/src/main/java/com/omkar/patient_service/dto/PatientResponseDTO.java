package com.omkar.patient_service.dto;

public record PatientResponseDTO(
        String id,
        String name,
        String email,
        String address,
        String dateOfBirth
) {
}
