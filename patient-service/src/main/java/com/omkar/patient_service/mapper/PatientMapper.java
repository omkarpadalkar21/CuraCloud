package com.omkar.patient_service.mapper;

import com.omkar.patient_service.dto.PatientResponseDTO;
import com.omkar.patient_service.model.Patient;
import org.mapstruct.Mapper;

@Mapper(componentModel = "spring")
public interface PatientMapper {
    PatientResponseDTO toDTO(Patient patient);
}
