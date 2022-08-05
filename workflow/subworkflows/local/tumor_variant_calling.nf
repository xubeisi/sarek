//
// TUMOR VARIANT CALLING
// Should be only run on patients without normal sample
//

include { RUN_FREEBAYES                           } from '../nf-core/variantcalling/freebayes/main.nf'
include { GATK_TUMOR_ONLY_SOMATIC_VARIANT_CALLING } from '../../subworkflows/nf-core/gatk4/tumor_only_somatic_variant_calling/main'
include { RUN_MANTA_TUMORONLY                     } from '../nf-core/variantcalling/manta/tumoronly/main.nf'
include { RUN_STRELKA_SINGLE                      } from '../nf-core/variantcalling/strelka/single/main.nf'
include { RUN_CONTROLFREEC_TUMORONLY              } from '../nf-core/variantcalling/controlfreec/tumoronly/main.nf'
include { RUN_CNVKIT                              } from '../nf-core/variantcalling/cnvkit/main.nf'
include { RUN_MPILEUP                             } from '../nf-core/variantcalling/mpileup/main'
include { RUN_TIDDIT                              } from '../nf-core/variantcalling/tiddit/single/main.nf'

workflow TUMOR_ONLY_VARIANT_CALLING {
    take:
        tools                         // Mandatory, list of tools to apply
        cram_recalibrated             // channel: [mandatory] cram
        bwa                           // channel: [optional] bwa
        chr_files
        cnvkit_reference
        dbsnp                         // channel: [mandatory] dbsnp
        dbsnp_tbi                     // channel: [mandatory] dbsnp_tbi
        dict                          // channel: [mandatory] dict
        fasta                         // channel: [mandatory] fasta
        fasta_fai                     // channel: [mandatory] fasta_fai
        germline_resource             // channel: [optional]  germline_resource
        germline_resource_tbi         // channel: [optional]  germline_resource_tbi
        intervals                     // channel: [mandatory] intervals/target regions
        intervals_bed_gz_tbi          // channel: [mandatory] intervals/target regions index zipped and indexed
        intervals_bed_combined        // channel: [mandatory] intervals/target regions in one file unzipped
        mappability
        panel_of_normals              // channel: [optional]  panel_of_normals
        panel_of_normals_tbi          // channel: [optional]  panel_of_normals_tbi

    main:

    ch_versions         = Channel.empty()

    //TODO: Temporary until the if's can be removed and printing to terminal is prevented with "when" in the modules.config
    freebayes_vcf       = Channel.empty()
    manta_vcf           = Channel.empty()
    mutect2_vcf         = Channel.empty()
    strelka_vcf         = Channel.empty()
    tiddit_vcf          = Channel.empty()

    // Remap channel with intervals
    cram_recalibrated_intervals = cram_recalibrated.combine(intervals)
        .map{ meta, cram, crai, intervals, num_intervals ->

            //If no interval file provided (0) then add empty list
            intervals_new = num_intervals == 0 ? [] : intervals

            [[
                data_type:      meta.data_type,
                id:             meta.sample,
                num_intervals:  num_intervals,
                patient:        meta.patient,
                sample:         meta.sample,
                sex:            meta.sex,
                status:         meta.status,
            ],
            cram, crai, intervals_new]
        }

    // Remap channel with gzipped intervals + indexes
    cram_recalibrated_intervals_gz_tbi = cram_recalibrated.combine(intervals_bed_gz_tbi)
        .map{ meta, cram, crai, bed_tbi, num_intervals ->

            //If no interval file provided (0) then add empty list
            bed_new = num_intervals == 0 ? [] : bed_tbi[0]
            tbi_new = num_intervals == 0 ? [] : bed_tbi[1]

            [[
                data_type:      meta.data_type,
                id:             meta.sample,
                num_intervals:  num_intervals,
                patient:        meta.patient,
                sample:         meta.sample,
                sex:            meta.sex,
                status:         meta.status,
            ],
            cram, crai, bed_new, tbi_new]
        }

    if (tools.split(',').contains('mpileup') || tools.split(',').contains('controlfreec')){
        cram_intervals_no_index = cram_recalibrated_intervals.map { meta, cram, crai, intervals ->
                                                                    [meta, cram, intervals]
                                                                    }
        RUN_MPILEUP(
            cram_intervals_no_index,
            fasta
        )

        ch_versions = ch_versions.mix(RUN_MPILEUP.out.versions)
    }

    if (tools.split(',').contains('controlfreec')){
        controlfreec_input = RUN_MPILEUP.out.mpileup
                                .map{ meta, pileup_tumor ->
                                    [meta, [], pileup_tumor, [], [], [], []]
                                }

        RUN_CONTROLFREEC_TUMORONLY(
            controlfreec_input,
            fasta,
            fasta_fai,
            dbsnp,
            dbsnp_tbi,
            chr_files,
            mappability,
            intervals_bed_combined
        )

        ch_versions = ch_versions.mix(RUN_CONTROLFREEC_TUMORONLY.out.versions)
    }

    if(tools.split(',').contains('cnvkit')){
        cram_recalibrated_cnvkit_tumoronly = cram_recalibrated
            .map{ meta, cram, crai ->
                [meta, cram, []]
            }

        RUN_CNVKIT (
            cram_recalibrated_cnvkit_tumoronly,
            fasta,
            fasta_fai,
            [],
            cnvkit_reference
        )

        ch_versions = ch_versions.mix(RUN_CNVKIT.out.versions)
    }

    if (tools.split(',').contains('freebayes')){
        // Remap channel for Freebayes
        cram_recalibrated_intervals_freebayes = cram_recalibrated_intervals
            .map{ meta, cram, crai, intervals ->
                [meta, cram, crai, [], [], intervals]
            }

        RUN_FREEBAYES(
            cram_recalibrated_intervals_freebayes,
            dict,
            fasta,
            fasta_fai
        )

        freebayes_vcf = RUN_FREEBAYES.out.freebayes_vcf
        ch_versions   = ch_versions.mix(RUN_FREEBAYES.out.versions)
    }

    if (tools.split(',').contains('mutect2')) {
        GATK_TUMOR_ONLY_SOMATIC_VARIANT_CALLING(
            cram_recalibrated_intervals,
            fasta,
            fasta_fai,
            dict,
            germline_resource,
            germline_resource_tbi,
            panel_of_normals,
            panel_of_normals_tbi
        )

        mutect2_vcf = GATK_TUMOR_ONLY_SOMATIC_VARIANT_CALLING.out.filtered_vcf
        ch_versions = ch_versions.mix(GATK_TUMOR_ONLY_SOMATIC_VARIANT_CALLING.out.versions)
    }

    if (tools.split(',').contains('manta')){

        RUN_MANTA_TUMORONLY(
            cram_recalibrated_intervals_gz_tbi,
            dict,
            fasta,
            fasta_fai
        )

        manta_vcf   = RUN_MANTA_TUMORONLY.out.manta_vcf
        ch_versions = ch_versions.mix(RUN_MANTA_TUMORONLY.out.versions)
    }

    if (tools.split(',').contains('strelka')) {

        RUN_STRELKA_SINGLE(
            cram_recalibrated_intervals_gz_tbi,
            dict,
            fasta,
            fasta_fai
        )

        strelka_vcf = RUN_STRELKA_SINGLE.out.strelka_vcf
        ch_versions = ch_versions.mix(RUN_STRELKA_SINGLE.out.versions)
    }

        //TIDDIT
    if (tools.split(',').contains('tiddit')){

        RUN_TIDDIT(
            cram_recalibrated,
            fasta,
            bwa
        )

        tiddit_vcf = RUN_TIDDIT.out.tiddit_vcf
        ch_versions = ch_versions.mix(RUN_TIDDIT.out.versions)
    }


    emit:
    freebayes_vcf
    manta_vcf
    mutect2_vcf
    strelka_vcf
    tiddit_vcf

    versions = ch_versions
}
